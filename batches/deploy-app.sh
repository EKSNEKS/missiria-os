#!/usr/bin/env bash
# deploy-app.sh — Universal deployer for MISSIRIA Next/Nest monorepos
# Usage: deploy <app-name>
# Apps are auto-discovered from /var/www/MISSIRIA/apps/<name>-app directories.
#
# Auto-rollback: on any failure between snapshot and successful health check,
# the previous git SHA + build artifacts + node_modules are restored and pm2 is
# restarted on the last-good version. A Telegram alert + log entry are emitted.
# Snapshots live under $APP_PATH/.deploy-snapshots/; last 3 kept, older pruned.

set -euo pipefail

export NVM_DIR="$HOME/.nvm"
# shellcheck source=/dev/null
[[ -s "$NVM_DIR/nvm.sh" ]] && \. "$NVM_DIR/nvm.sh"

BASE_DIR="/var/www/MISSIRIA/apps"
ROLLBACK_LOG="/var/log/deploy-rollback.log"

# Telegram alert config (override via env if needed)
TG_TOKEN="${DEPLOY_TG_TOKEN:-8769151688:AAEuMvNmJq9VgmazsPZOO0uKuPqDom7ZFNE}"
TG_CHAT="${DEPLOY_TG_CHAT:-8905329318}"

# ─── State shared with rollback trap ──────────────────────────────────────────
APP_NAME=""
APP_PATH=""
ECOSYSTEM=""
PM2_NAMES=""
PREV_SHA=""
SNAPSHOT_DIR=""
DEPLOY_STARTED=0
DEPLOY_SUCCEEDED=0

# ─── Helpers ──────────────────────────────────────────────────────────────────

tg_alert() {
  local text="$1"
  [[ -z "$TG_TOKEN" || -z "$TG_CHAT" ]] && return 0
  curl -s --max-time 15 "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT}" \
    --data-urlencode "text=${text}" >/dev/null 2>&1 || true
}

log_rollback() {
  local msg="$1"
  mkdir -p "$(dirname "$ROLLBACK_LOG")" 2>/dev/null || true
  echo "$(date -Iseconds) [${APP_NAME:-?}] $msg" >> "$ROLLBACK_LOG" 2>/dev/null || true
}

# List all discoverable app names (dirs ending in -app → strip suffix)
list_apps() {
  for d in "$BASE_DIR"/*/; do
    local dir
    dir=$(basename "$d")
    [[ "$dir" == *-app ]] && echo "${dir%-app}"
  done
}

# Find ecosystem config: check root then deploy/
find_ecosystem() {
  local app_path="$1"
  for candidate in "ecosystem.config.cjs" "deploy/ecosystem.config.cjs" "ecosystem.config.js"; do
    [[ -f "$app_path/$candidate" ]] && echo "$candidate" && return
  done
  echo ""
}

# Extract PM2 app names from ecosystem config
extract_pm2_names() {
  local ecosystem_file="$1"
  grep -oP "(?<=name:\s['\"])[^'\"]+(?=['\"])" "$ecosystem_file" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
}

# Check if package.json has a db:migrate script
has_migrate() {
  local app_path="$1"
  grep -q '"db:migrate"' "$app_path/package.json" 2>/dev/null && echo "yes" || echo "no"
}

# Discover local upstream ports from deploy/nginx/*.conf → "8010 8011"
discover_upstream_ports() {
  local app_path="$1"
  local ports=""
  if compgen -G "$app_path/deploy/nginx/*.conf" > /dev/null; then
    ports=$(grep -hoE 'server[[:space:]]+127\.0\.0\.1:[0-9]+' "$app_path/deploy/nginx/"*.conf 2>/dev/null \
              | grep -oE '[0-9]+$' | sort -u | tr '\n' ' ' | sed 's/ $//')
  fi
  echo "$ports"
}

# ─── Rollback trap ────────────────────────────────────────────────────────────

rollback() {
  local exit_code=$?
  # Guard: don't fire on successful exit or before snapshot was taken
  [[ "$DEPLOY_SUCCEEDED" == "1" ]] && return 0
  [[ "$DEPLOY_STARTED" != "1" ]] && exit "$exit_code"

  set +e
  trap - ERR EXIT
  echo ""
  echo "🚨 ============================================"
  echo "🚨  DEPLOY FAILED (exit=$exit_code) — auto-rollback"
  echo "🚨  App: $APP_NAME  →  restoring ${PREV_SHA:0:8}"
  echo "🚨 ============================================"

  cd "$APP_PATH" 2>/dev/null || {
    log_rollback "FATAL: APP_PATH gone ($APP_PATH); cannot rollback"
    tg_alert "🚨 [${APP_NAME}] DEPLOY FAILED — APP_PATH missing, MANUAL RECOVERY REQUIRED"
    exit "$exit_code"
  }

  # Restore git tree
  if [[ -n "$PREV_SHA" ]]; then
    git reset --hard "$PREV_SHA" >/dev/null 2>&1 \
      && echo "   ✅ git reset --hard $PREV_SHA" \
      || echo "   ⚠️  git reset failed"
  fi

  # Restore build + deps from snapshot (in-place swap)
  if [[ -n "$SNAPSHOT_DIR" && -d "$SNAPSHOT_DIR" ]]; then
    rm -rf node_modules api/node_modules web/node_modules api/dist web/.next 2>/dev/null
    [[ -d "$SNAPSHOT_DIR/node_modules"      ]] && mv "$SNAPSHOT_DIR/node_modules"     node_modules      && echo "   ✅ restored node_modules"
    [[ -d "$SNAPSHOT_DIR/api-node_modules"  ]] && mv "$SNAPSHOT_DIR/api-node_modules" api/node_modules  && echo "   ✅ restored api/node_modules"
    [[ -d "$SNAPSHOT_DIR/web-node_modules"  ]] && mv "$SNAPSHOT_DIR/web-node_modules" web/node_modules  && echo "   ✅ restored web/node_modules"
    [[ -d "$SNAPSHOT_DIR/api-dist"          ]] && mv "$SNAPSHOT_DIR/api-dist"         api/dist          && echo "   ✅ restored api/dist"
    [[ -d "$SNAPSHOT_DIR/web-next"          ]] && mv "$SNAPSHOT_DIR/web-next"        web/.next         && echo "   ✅ restored web/.next"
    [[ -f "$SNAPSHOT_DIR/package-lock.json" ]] && cp "$SNAPSHOT_DIR/package-lock.json" package-lock.json && echo "   ✅ restored package-lock.json"
    rmdir "$SNAPSHOT_DIR" 2>/dev/null || true
  else
    echo "   ⚠️  no snapshot dir; skipping artifact restore"
  fi

  # Restart PM2 on restored artifacts
  if [[ -n "$ECOSYSTEM" && -f "$APP_PATH/$ECOSYSTEM" ]]; then
    pm2 reload "$APP_PATH/$ECOSYSTEM" --update-env >/dev/null 2>&1 \
      || pm2 start "$APP_PATH/$ECOSYSTEM" --update-env >/dev/null 2>&1 \
      || echo "   ⚠️  pm2 restart failed — MANUAL INTERVENTION REQUIRED"
    echo "   ✅ pm2 restart attempted on restored version"
  fi

  local msg="🚨 [${APP_NAME}] DEPLOY FAILED (exit ${exit_code}) — rolled back to ${PREV_SHA:0:8}. Investigate: pm2 logs ${PM2_NAMES} --lines 100"
  log_rollback "$msg"
  tg_alert "$msg"

  echo ""
  echo "🚨 Rollback complete. Alert sent."
  exit "$exit_code"
}

trap rollback ERR
# EXIT trap needed because `set -e` alone can miss failures in some contexts;
# rollback() self-guards on DEPLOY_SUCCEEDED so no double-fire.
trap rollback EXIT

# ─── Validate input ───────────────────────────────────────────────────────────
APP_NAME="${1:-}"

AVAILABLE=$(list_apps | sort | tr '\n' ' ' | sed 's/ $//')

if [[ -z "$APP_NAME" ]]; then
  echo "❌ Usage: deploy <app-name>"
  echo "   Available: $AVAILABLE"
  trap - ERR EXIT
  exit 1
fi

APP_PATH="$BASE_DIR/${APP_NAME}-app"

if [[ ! -d "$APP_PATH" ]]; then
  echo "❌ Unknown app: '$APP_NAME'"
  echo "   Available: $AVAILABLE"
  trap - ERR EXIT
  exit 1
fi

# ─── Auto-detect config ───────────────────────────────────────────────────────
ECOSYSTEM=$(find_ecosystem "$APP_PATH")
HAS_MIGRATE=$(has_migrate "$APP_PATH")

if [[ -n "$ECOSYSTEM" ]]; then
  PM2_NAMES=$(extract_pm2_names "$APP_PATH/$ECOSYSTEM")
else
  PM2_NAMES=""
fi

if [[ -z "$PM2_NAMES" ]]; then
  echo "❌ Could not detect PM2 process names from ecosystem config."
  echo "   Expected ecosystem.config.cjs in $APP_PATH or $APP_PATH/deploy/"
  trap - ERR EXIT
  exit 1
fi

UPSTREAM_PORTS=$(discover_upstream_ports "$APP_PATH")

# ─── Deploy ───────────────────────────────────────────────────────────────────
STEP=1
TOTAL=9
[[ "$HAS_MIGRATE" == "yes" ]] && TOTAL=10

label() { printf "\n📦 [%s/%s] %s\n" "$STEP" "$TOTAL" "$1"; STEP=$((STEP+1)); }

echo ""
echo "🚀 ======================================="
printf "🚀  Deploying: %s\n" "${APP_NAME^^} APP"
echo "🚀  Path: $APP_PATH"
echo "🚀  PM2:  $PM2_NAMES"
echo "🚀  Health-check ports: ${UPSTREAM_PORTS:-<none-detected>}"
echo "🚀 ======================================="
echo ""

# Capture PREV_SHA *before* git pull so we can rollback even if pull is a no-op.
cd "$APP_PATH"
PREV_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")

label "Pulling latest code..."
# npm install rewrites package-lock.json on the server; it is generated
# content — discard local drift so the pull never aborts on it.
git checkout -- package-lock.json 2>/dev/null || true
git pull

NEW_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")
if [[ -n "$PREV_SHA" && "$PREV_SHA" == "$NEW_SHA" ]]; then
  echo "   ℹ️  Already up-to-date at ${PREV_SHA:0:8}; deploy still proceeds (idempotent)."
fi

label "Snapshotting previous build (for auto-rollback)..."
SNAPSHOT_DIR="$APP_PATH/.deploy-snapshots/$(date +%Y%m%d-%H%M%S)-${PREV_SHA:0:8}"
mkdir -p "$SNAPSHOT_DIR"
DEPLOY_STARTED=1
[[ -d node_modules      ]] && mv node_modules      "$SNAPSHOT_DIR/node_modules"      && echo "   📸 node_modules"
[[ -d api/node_modules  ]] && mv api/node_modules  "$SNAPSHOT_DIR/api-node_modules"  && echo "   📸 api/node_modules"
[[ -d web/node_modules  ]] && mv web/node_modules  "$SNAPSHOT_DIR/web-node_modules"  && echo "   📸 web/node_modules"
[[ -d api/dist          ]] && mv api/dist          "$SNAPSHOT_DIR/api-dist"          && echo "   📸 api/dist"
[[ -d web/.next         ]] && mv web/.next         "$SNAPSHOT_DIR/web-next"          && echo "   📸 web/.next"
[[ -f package-lock.json ]] && cp package-lock.json "$SNAPSHOT_DIR/package-lock.json" && echo "   📸 package-lock.json"
echo "   ✅ Snapshot at: $SNAPSHOT_DIR"

label "Stopping PM2 processes (release file handles on node_modules)..."
if [[ -n "$PM2_NAMES" ]]; then
  # shellcheck disable=SC2086
  pm2 stop $PM2_NAMES 2>/dev/null || true
  echo "   ✅ PM2 stopped: $PM2_NAMES"
fi

label "Cleaning any straggler build artifacts..."
# Defensive: snapshot mv should have emptied these; catch anything left.
rm -rf node_modules web/node_modules api/node_modules web/.next api/dist
if [[ -d node_modules || -d web/node_modules || -d api/node_modules ]]; then
  sleep 1
  rm -rf node_modules web/node_modules api/node_modules web/.next api/dist
fi
if [[ -d node_modules || -d web/node_modules || -d api/node_modules ]]; then
  echo "❌ Clean failed — node_modules dirs still present."
  echo "   Check open handles: lsof +D node_modules 2>/dev/null | head -5"
  exit 1
fi
echo "   ✅ Clean done"

label "Installing dependencies..."
# Force dev-mode install so devDependencies (nest CLI, next, etc.) are pulled
# even when NODE_ENV=production is inherited from the deploy shell.
# --ignore-scripts avoids race where unrs-resolver postinstall fires before
# napi-postinstall is fully linked; npm rebuild after runs the deferred scripts.
# Redirect stderr→stdout and filter via a real pipe so PIPESTATUS reflects npm's
# actual exit code (the old `2> >(grep ...)` process-substitution masked failures
# and left partial node_modules that broke the build later).
NODE_ENV=development npm install --include=optional --include=dev --ignore-scripts 2>&1 \
  | grep -vE "^npm warn deprecated" || true
if [[ ${PIPESTATUS[0]} -ne 0 ]]; then echo "❌ npm install failed"; exit 1; fi
NODE_ENV=development npm rebuild 2>&1 \
  | grep -vE "^npm warn deprecated" || true
if [[ ${PIPESTATUS[0]} -ne 0 ]]; then echo "❌ npm rebuild failed"; exit 1; fi

# Sanity: if the app has an api workspace, nest CLI must be linked in .bin.
if [[ -f "$APP_PATH/api/package.json" ]] && ! [[ -x "$APP_PATH/node_modules/.bin/nest" || -x "$APP_PATH/api/node_modules/.bin/nest" ]]; then
  echo "❌ npm install completed but @nestjs/cli was not linked into node_modules/.bin"
  exit 1
fi

label "Building API + Web..."
npm run build || { echo "❌ Build failed"; exit 1; }

if [[ "$HAS_MIGRATE" == "yes" ]]; then
  label "Running database migrations..."
  npm run db:migrate || { echo "❌ Migration failed"; exit 1; }
fi

label "Reloading PM2 processes (${PM2_NAMES})..."
pm2 reload "$APP_PATH/$ECOSYSTEM" --update-env || { echo "❌ PM2 reload failed"; exit 1; }

label "Health check (pm2 status + upstream ports)..."
sleep 3  # give processes a moment to bind ports
HEALTH_OK=0
HAS_JQ=$(command -v jq >/dev/null 2>&1 && echo 1 || echo 0)
for attempt in 1 2 3 4 5 6; do
  # 1) pm2 status: every named app must be 'online'
  all_online=1
  for name in $PM2_NAMES; do
    if [[ "$HAS_JQ" == "1" ]]; then
      status=$(pm2 jlist 2>/dev/null | jq -r --arg n "$name" '.[] | select(.name==$n) | .pm2_env.status' | head -1)
    else
      status=$(pm2 jlist 2>/dev/null | grep -oE "\"name\":\"${name}\"[^}]*\"status\":\"[a-z]+\"" | grep -oE '"status":"[a-z]+"' | tail -1 | grep -oE '[a-z]+"' | tr -d '"')
    fi
    if [[ "$status" != "online" ]]; then
      all_online=0
      echo "   ⚠️  attempt $attempt/6: pm2 process '$name' status='${status:-unknown}'"
    fi
  done

  # 2) port probe: every discovered upstream must accept a TCP connection
  all_ports=1
  if [[ -n "$UPSTREAM_PORTS" ]]; then
    for port in $UPSTREAM_PORTS; do
      code=$(curl -s -o /dev/null --max-time 4 -w '%{http_code}' "http://127.0.0.1:${port}/" 2>/dev/null || echo "000")
      # 000 = connection refused/timeout = down; any HTTP code = Node responded
      if [[ "$code" == "000" ]]; then
        all_ports=0
        echo "   ⚠️  attempt $attempt/6: port $port not responding (curl 000)"
      fi
    done
  fi

  if [[ "$all_online" == "1" && "$all_ports" == "1" ]]; then
    HEALTH_OK=1
    echo "   ✅ Health check passed (attempt $attempt/6)"
    break
  fi
  sleep 5
done

if [[ "$HEALTH_OK" != "1" ]]; then
  echo "❌ Health check failed after 6 attempts (~30s)"
  exit 1
fi

label "Clearing caches (Next.js / Varnish / Redis / Nginx)..."
if [[ -d "$APP_PATH/web/.next/cache" ]]; then
  rm -rf "$APP_PATH/web/.next/cache" && echo "   ✅ Next.js route/fetch cache cleared" || echo "   ⚠️  Next.js cache clear failed"
fi
if systemctl is-active --quiet varnish && command -v varnishadm &>/dev/null; then
  varnishadm ban 'req.url ~ .' && echo "   ✅ Varnish cache cleared" || echo "   ⚠️  Varnish clear failed"
else
  echo "   ⏭️  Varnish not running — skipped"
fi
if command -v redis-cli &>/dev/null && redis-cli ping &>/dev/null; then
  redis-cli FLUSHALL && echo "   ✅ Redis cache cleared" || echo "   ⚠️  Redis flush failed"
else
  echo "   ⏭️  Redis not running — skipped"
fi
if systemctl is-active --quiet nginx; then
  systemctl reload nginx && echo "   ✅ Nginx reloaded" || echo "   ⚠️  Nginx reload failed"
else
  echo "   ⏭️  Nginx not running — skipped"
fi

# ─── Success: prune trap, clean snapshots ────────────────────────────────────
DEPLOY_SUCCEEDED=1
trap - ERR EXIT

# Retention: keep last 3 snapshots
if [[ -d "$APP_PATH/.deploy-snapshots" ]]; then
  # shellcheck disable=SC2012
  ls -1dt "$APP_PATH/.deploy-snapshots"/*/ 2>/dev/null | tail -n +4 | while read -r old; do
    rm -rf "$old" && echo "   🧹 Pruned old snapshot: $(basename "$old")"
  done
fi

echo ""
echo "✅ ======================================="
printf "✅  %s deployed successfully!\n" "${APP_NAME^^} APP"
echo "✅ ======================================="
echo ""
pm2 list

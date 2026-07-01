#!/usr/bin/env bash
# deploy-app.sh — Universal deployer for MISSIRIA Next/Nest monorepos
# Usage: deploy <app-name>
# Apps are auto-discovered from /var/www/MISSIRIA/apps/<name>-app directories.

set -euo pipefail

export NVM_DIR="$HOME/.nvm"
# shellcheck source=/dev/null
[[ -s "$NVM_DIR/nvm.sh" ]] && \. "$NVM_DIR/nvm.sh"

BASE_DIR="/var/www/MISSIRIA/apps"

# ─── Auto-discovery helpers ──────────────────────────────────────────────────

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

# ─── Validate input ───────────────────────────────────────────────────────────
APP_NAME="${1:-}"

AVAILABLE=$(list_apps | sort | tr '\n' ' ' | sed 's/ $//')

if [[ -z "$APP_NAME" ]]; then
  echo "❌ Usage: deploy <app-name>"
  echo "   Available: $AVAILABLE"
  exit 1
fi

APP_PATH="$BASE_DIR/${APP_NAME}-app"

if [[ ! -d "$APP_PATH" ]]; then
  echo "❌ Unknown app: '$APP_NAME'"
  echo "   Available: $AVAILABLE"
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
  exit 1
fi

# ─── Deploy ───────────────────────────────────────────────────────────────────
STEP=1
TOTAL=6
[[ "$HAS_MIGRATE" == "yes" ]] && TOTAL=7

label() { printf "\n📦 [%s/%s] %s\n" "$STEP" "$TOTAL" "$1"; STEP=$((STEP+1)); }

echo ""
echo "🚀 ======================================="
printf "🚀  Deploying: %s\n" "${APP_NAME^^} APP"
echo "🚀  Path: $APP_PATH"
echo "🚀  PM2:  $PM2_NAMES"
echo "🚀 ======================================="
echo ""

label "Pulling latest code..."
cd "$APP_PATH" && git pull || { echo "❌ git pull failed"; exit 1; }

label "Cleaning build artifacts & node_modules..."
rm -rf node_modules web/node_modules api/node_modules web/.next api/dist
echo "   ✅ Clean done"

label "Installing dependencies..."
# Filter transitive-dep deprecation warnings on stderr (jest→glob@7, typeorm→glob@10, etc.).
# --ignore-scripts avoids race where unrs-resolver postinstall fires before
# napi-postinstall is fully linked; npm rebuild after runs the deferred scripts.
npm install --include=optional --include=dev --ignore-scripts 2> >(grep -vE "^npm warn deprecated" >&2) \
  || { echo "❌ npm install failed"; exit 1; }
npm rebuild 2> >(grep -vE "^npm warn deprecated" >&2) \
  || { echo "❌ npm rebuild failed"; exit 1; }

label "Building API + Web..."
npm run build || { echo "❌ Build failed"; exit 1; }

if [[ "$HAS_MIGRATE" == "yes" ]]; then
  label "Running database migrations..."
  npm run db:migrate || { echo "❌ Migration failed"; exit 1; }
fi

label "Reloading PM2 processes (${PM2_NAMES})..."
pm2 reload "$APP_PATH/$ECOSYSTEM" --update-env || { echo "❌ PM2 reload failed"; exit 1; }

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

echo ""
echo "✅ ======================================="
printf "✅  %s deployed successfully!\n" "${APP_NAME^^} APP"
echo "✅ ======================================="
echo ""
pm2 list

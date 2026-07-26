#!/usr/bin/env bash
# import-site.sh — fill an existing wp-hosting-stack tenant with a sister site's DATABASE.
#
#   sudo ./import-site.sh <target-domain> --from-local  <source-domain>
#   sudo ./import-site.sh <target-domain> --from-remote <ssh-host> --remote-db <db>
#   sudo ./import-site.sh <target-domain> --from-file   <dump.sql>
#   … [--dry-run] [--mail-pass <pw>] [--no-notify]
#
# By default it also wires MISSIRIA notifications (Telegram + SMTP) into
# wp-config.php so order/lead alerts and client emails work immediately:
#   - shared secrets (bot token, chat id, SMTP host/port/secure) are read from
#     /etc/wp-hosting/missiria-notify.conf (root:600) — never hardcoded here;
#   - a contact@<domain> mailbox is created (mailadd) for SMTP auth, its password
#     saved to the site .env; use --mail-pass to set a specific one, --no-notify to skip.
#
# DB ONLY by design: no uploads, no wp-content sync — theme/plugin files come from the
# tenant's repo/ checkout (deploy-wp <domain>). Media referenced by the imported DB will
# 404 until uploads are handled separately.
#
# What it does:
#   1. loads /etc/wp-hosting/sites/<target>.env  (tenant must exist — create-site.sh first)
#   2. backs up the target DB + wp-config.php to /var/www/<target>/.import-backups/<ts>/
#   3. dumps the source DB (local sister env creds / ssh remote mysqldump / given file)
#   4. detects the source table prefix from the dump and sets it in the target wp-config
#   5. drops the target DB tables and imports the dump (target DB user creds — no root)
#   6. if the source domain differs: wp search-replace (www pass then bare pass), all tables
#   7. flushes Redis object cache + nginx FastCGI cache, then health-checks the homepage
#
# Idempotent: re-running just re-imports. Backups keep the last 3 runs.
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root

# MariaDB 11 ships mariadb/mariadb-dump (no mysql symlinks); old VPS has mysqldump.
MYSQL_BIN="$(command -v mariadb || command -v mysql)"
MYSQLDUMP_BIN="$(command -v mariadb-dump || command -v mysqldump)"

SITES_DIR="${STACK_STATE_DIR:-/etc/wp-hosting}/sites"
KEEP_BACKUPS=3

usage() {
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

TARGET="${1:-}"; [[ -n "$TARGET" && "$TARGET" != -* ]] || usage
shift
MODE=""; SRC_DOMAIN=""; RHOST=""; RDB=""; SRC_FILE=""; DRY=0; MAILPASS=""; NO_NOTIFY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-local)  MODE=local;  SRC_DOMAIN="${2:?}"; shift 2 ;;
    --from-remote) MODE=remote; RHOST="${2:?}";      shift 2 ;;
    --remote-db)   RDB="${2:?}"; shift 2 ;;
    --from-file)   MODE=file;   SRC_FILE="${2:?}";   shift 2 ;;
    --mail-pass)   MAILPASS="${2:?}"; shift 2 ;;   # password for contact@<domain> + SMTP auth
    --no-notify)   NO_NOTIFY=1; shift ;;           # skip Telegram/SMTP wp-config constants
    --dry-run)     DRY=1; shift ;;
    *) err "unknown option: $1"; usage ;;
  esac
done
[[ -n "$MODE" ]] || usage
[[ "$MODE" != remote || -n "$RDB" ]] || { err "--from-remote needs --remote-db"; usage; }

# --- read a site env file into PREFIX_* variables without clobbering ours ---
load_env() { # <domain> <var-prefix>
  local f="$SITES_DIR/$1.env" line key val
  [[ -f "$f" ]] || { err "no site record: $f — run create-site.sh $1 first"; exit 1; }
  while IFS='=' read -r key val; do
    [[ "$key" =~ ^[A-Z_]+$ ]] || continue
    val="${val%\"}"; val="${val#\"}"
    printf -v "$2$key" '%s' "$val"
  done < <(grep -E '^[A-Z_]+=' "$f")
}

section "Import into $TARGET (mode: $MODE)"
load_env "$TARGET" TGT_
[[ -f "$TGT_DOCROOT/wp-config.php" ]] || { err "no wp-config.php in $TGT_DOCROOT"; exit 1; }
run_as() { sudo -u "$TGT_SYSUSER" -H env PATH="/usr/local/bin:/usr/bin:/bin" "$@"; }
tgt_mysql() { "$MYSQL_BIN" --user="$TGT_DB_USER" --password="$TGT_DB_PASS" "$TGT_DB_NAME" "$@"; }

TS="$(date +%Y%m%d-%H%M%S)"
BK_ROOT="/var/www/$TARGET/.import-backups"
BK="$BK_ROOT/$TS"
WORK="$(mktemp -d /tmp/import-site.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
DUMP="$WORK/source.sql"

# --- 1. source dump ---------------------------------------------------------
section "1/6 Dump source database"
case "$MODE" in
  local)
    load_env "$SRC_DOMAIN" SRC_
    log "source: $SRC_DOMAIN (db $SRC_DB_NAME, local)"
    "$MYSQLDUMP_BIN" --user="$SRC_DB_USER" --password="$SRC_DB_PASS" \
      --single-transaction --quick --no-tablespaces "$SRC_DB_NAME" > "$DUMP"
    ;;
  remote)
    log "source: $RHOST db $RDB (remote, read-only)"
    ssh -o BatchMode=yes -o ConnectTimeout=15 "$RHOST" \
      "command -v mariadb-dump >/dev/null 2>&1 && mariadb-dump --single-transaction --quick --no-tablespaces '$RDB' || mysqldump --single-transaction --quick --no-tablespaces '$RDB'" > "$DUMP"
    ;;
  file)
    [[ -f "$SRC_FILE" ]] || { err "no such file: $SRC_FILE"; exit 1; }
    cp "$SRC_FILE" "$DUMP"
    ;;
esac
ok "dump: $(du -h "$DUMP" | cut -f1)"

# --- 2. detect prefix + source domain from the dump -------------------------
SRC_PREFIX="$(grep -m1 -oE 'CREATE TABLE `[A-Za-z0-9_]+options`' "$DUMP" | sed -E 's/CREATE TABLE `(.*)options`/\1/')"
[[ -n "$SRC_PREFIX" ]] || { err "could not detect table prefix (no *options table in dump)"; exit 1; }
SRC_URL="$(grep -m1 -oE "'siteurl','https?://[^']+'" "$DUMP" | sed -E "s/'siteurl','([^']+)'/\1/")"
SRC_HOST="${SRC_URL#*://}"; SRC_HOST="${SRC_HOST%%/*}"
SRC_BARE="${SRC_HOST#www.}"
log "source prefix : $SRC_PREFIX"
log "source siteurl: ${SRC_URL:-<none found>}"

if [[ $DRY -eq 1 ]]; then
  section "DRY RUN — would do"
  log "backup  : $TGT_DB_NAME + wp-config.php -> $BK/"
  log "prefix  : wp config set table_prefix $SRC_PREFIX"
  log "import  : drop all tables in $TGT_DB_NAME, import $(du -h "$DUMP" | cut -f1) dump"
  [[ -n "$SRC_BARE" && "$SRC_BARE" != "$TARGET" ]] \
    && log "rewrite : www.$SRC_BARE -> www.$TARGET, then $SRC_BARE -> $TARGET (all tables)" \
    || log "rewrite : skipped (same domain)"
  log "caches  : wp cache flush + FastCGI purge, then homepage health check"
  exit 0
fi

# --- 3. backup target -------------------------------------------------------
section "2/6 Backup target"
mkdir -p "$BK"
"$MYSQLDUMP_BIN" --user="$TGT_DB_USER" --password="$TGT_DB_PASS" \
  --single-transaction --quick --no-tablespaces "$TGT_DB_NAME" | gzip > "$BK/db-before.sql.gz"
cp -a "$TGT_DOCROOT/wp-config.php" "$BK/wp-config.php"
ok "backup at $BK"
ls -1dt "$BK_ROOT"/*/ 2>/dev/null | tail -n +$((KEEP_BACKUPS+1)) | xargs -r rm -rf

# --- 4. table prefix --------------------------------------------------------
section "3/6 Set table prefix"
run_as wp config set table_prefix "$SRC_PREFIX" --path="$TGT_DOCROOT" >/dev/null
ok "table_prefix = $SRC_PREFIX"

# --- 5. import --------------------------------------------------------------
section "4/6 Import database"
# Wipe ALL existing tables (vanilla install + any prior import) so nothing from a
# different prefix is left behind. wp db reset is prefix-agnostic (drops the whole DB).
run_as wp db reset --yes --path="$TGT_DOCROOT" >/dev/null 2>&1 || {
  warn "wp db reset unavailable — falling back to manual drop"
  { echo "SET FOREIGN_KEY_CHECKS=0;"
    tgt_mysql -N -e "SHOW TABLES" | while read -r t; do echo "DROP TABLE IF EXISTS \`$t\`;"; done
  } | tgt_mysql
}
tgt_mysql < "$DUMP"
ok "imported into $TGT_DB_NAME ($(tgt_mysql -N -e 'SHOW TABLES' | wc -l) tables)"

# --- 6. URL rewrite ---------------------------------------------------------
section "5/6 URL rewrite"
if [[ -n "$SRC_BARE" && "$SRC_BARE" != "$TARGET" ]]; then
  run_as wp search-replace "www.$SRC_BARE" "www.$TARGET" --all-tables --report-changed-only --path="$TGT_DOCROOT"
  run_as wp search-replace "$SRC_BARE" "$TARGET" --all-tables --report-changed-only --path="$TGT_DOCROOT"
  ok "siteurl now: $(run_as wp option get siteurl --path="$TGT_DOCROOT")"
else
  log "same domain — rewrite skipped"
fi

# Cloned DBs inherit the source's "Discourage search engines" flag; force the site
# indexable so a clone is never silently noindex+disallow-all (MITP-0072).
run_as wp option update blog_public 1 --path="$TGT_DOCROOT" >/dev/null 2>&1 \
  && ok "blog_public=1 (search engines allowed)"

# --- 7. notifications: Telegram + SMTP constants (default) ------------------
# Writes the MISSIRIA_* constants MISSIRIA_core needs so order/lead Telegram
# alerts + client order emails work out of the box. Shared secrets (bot token,
# chat id, SMTP host/port) come from a root-only config file so nothing sensitive
# lives in this script or the repo. Per-site values (SMTP user/from) are derived
# from the domain; the SMTP password is the site's own contact@ mailbox password.
if [[ $NO_NOTIFY -eq 0 ]]; then
  section "Notifications (Telegram + SMTP)"
  NOTIFY_CONF="${STACK_STATE_DIR:-/etc/wp-hosting}/missiria-notify.conf"
  if [[ -f "$NOTIFY_CONF" ]]; then
    # shellcheck disable=SC1090
    source "$NOTIFY_CONF"   # provides: TG_BOT_TOKEN TG_CHAT_ID SMTP_HOST SMTP_PORT SMTP_SECURE
    cfg(){ run_as wp config set "$@" --path="$TGT_DOCROOT" >/dev/null 2>&1; }

    # contact@<domain> mailbox (SMTP auth). Create if the mail stack is present.
    mailpw="$MAILPASS"
    if command -v mailadd >/dev/null 2>&1; then
      [[ -n "$mailpw" ]] || mailpw="$(openssl rand -base64 15 | tr -d '/+=' | head -c 16)"
      if mailadd "contact@$TARGET" "$mailpw" >/dev/null 2>&1; then
        ok "mailbox contact@$TARGET ready"
        grep -q '^MAIL_CONTACT_PASS=' "$SITES_DIR/$TARGET.env" 2>/dev/null \
          || echo "MAIL_CONTACT_PASS=\"$mailpw\"" >> "$SITES_DIR/$TARGET.env"
      else
        warn "mailadd failed (mailbox may already exist) — pass --mail-pass to set SMTP_PASSWORD to match"
        mailpw="$MAILPASS"   # only trust an explicitly supplied password now
      fi
    fi

    # Telegram (shared MIT bot)
    [[ -n "${TG_BOT_TOKEN:-}" ]] && cfg MISSIRIA_TG_BOT_TOKEN "$TG_BOT_TOKEN" --type=constant
    [[ -n "${TG_CHAT_ID:-}"   ]] && cfg MISSIRIA_TG_CHAT_ID   "$TG_CHAT_ID"   --type=constant
    # SMTP. Default = local Postfix relay (WP + mail on the same box): most
    # reliable, no auth needed. MISSIRIA_smtp still requires HOST/USERNAME/PASSWORD
    # to be DEFINED (ConfigModel guard), so we set them even when auth is off.
    cfg MISSIRIA_SMTP_HOST   "${SMTP_HOST:-localhost}" --type=constant
    cfg MISSIRIA_SMTP_PORT   "${SMTP_PORT:-25}"        --type=constant --raw
    cfg MISSIRIA_SMTP_SECURE "${SMTP_SECURE:-}"        --type=constant
    cfg MISSIRIA_SMTP_AUTH   "${SMTP_AUTH:-false}"     --type=constant --raw
    cfg MISSIRIA_SMTP_USERNAME   "contact@$TARGET" --type=constant
    cfg MISSIRIA_SMTP_FROM_EMAIL "contact@$TARGET" --type=constant
    site_name="$(run_as wp option get blogname --path="$TGT_DOCROOT" 2>/dev/null)"
    cfg MISSIRIA_SMTP_FROM_NAME  "${site_name:-$TARGET}" --type=constant
    [[ -n "$mailpw" ]] && cfg MISSIRIA_SMTP_PASSWORD "$mailpw" --type=constant \
      || warn "SMTP_PASSWORD not set (no mailbox password) — pass --mail-pass or set it later"
    ok "Telegram + SMTP constants written to wp-config.php"
  else
    warn "no $NOTIFY_CONF — skipping Telegram/SMTP defaults."
    warn "create it (root:600) with: TG_BOT_TOKEN, TG_CHAT_ID, SMTP_HOST, SMTP_PORT, SMTP_SECURE"
  fi
fi

# --- 8. caches + health -----------------------------------------------------
section "6/6 Caches & health check"
run_as wp cache flush --path="$TGT_DOCROOT" >/dev/null 2>&1 || warn "wp cache flush failed (redis?)"
run_as wp rewrite flush --path="$TGT_DOCROOT" >/dev/null 2>&1 || true
if [[ -d "${FASTCGI_CACHE_ROOT:-/var/cache/nginx/fastcgi}" ]]; then
  rm -rf "${FASTCGI_CACHE_ROOT:-/var/cache/nginx/fastcgi}"/* 2>/dev/null || true
  ok "FastCGI cache purged"
fi

code="$(curl -sk -o "$WORK/home.html" -w '%{http_code}' --resolve "www.$TARGET:443:127.0.0.1" "https://www.$TARGET/" || true)"
if [[ "$code" != "200" ]]; then
  # No-SSL tenant (pre-cutover): probe HTTP; a 301 to the site's own https URL means WP answered.
  http_out="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --resolve "www.$TARGET:80:127.0.0.1" "http://www.$TARGET/" || true)"
  [[ "$http_out" == 301\ *"$TARGET"* || "$http_out" == 308\ *"$TARGET"* ]] && code="200(via http 301)"
fi
if [[ "$code" == 200* ]]; then
  ok "health: www.$TARGET -> $code"
else
  warn "health: https://www.$TARGET/ -> $code"
  warn "restore: gunzip -c $BK/db-before.sql.gz | mysql -u $TGT_DB_USER -p'***' $TGT_DB_NAME"
  warn "         cp $BK/wp-config.php $TGT_DOCROOT/wp-config.php"
  exit 1
fi

section "Done"
log "next: sudo deploy-wp $TARGET   # sync theme/mu-plugins from the repo checkout"

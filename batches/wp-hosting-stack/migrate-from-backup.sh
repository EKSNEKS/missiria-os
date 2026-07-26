#!/usr/bin/env bash
# migrate-from-backup.sh — migrate a WordPress site from the old-VPS nightly
# backups (/var/backups/missiria-auto/<ts>/<domain>/) onto this paradiso stack.
#
#   sudo ./migrate-from-backup.sh <domain> [options]
#     --backup <YYYYmmdd_HHMMSS>   pick a specific backup (default: latest containing the domain)
#     --source <ssh-host>          where the backups live (default: root@81.17.98.31)
#     --ssl                        issue TLS now (DNS must already point here); default: --no-ssl
#     --dry-run                    resolve + print the plan, change nothing
#     --force                      re-run over an existing tenant
#
# Full same-domain migration: provisions an isolated tenant (create-site.sh, blank WP),
# then overlays the backup's wp-content + database. Old VPS is read-only. No DNS/Cloudflare
# change — cut over the Cloudflare origin afterwards, then re-run create-site for the cert.
#
# Prereq: this host's SSH key must be authorised on <source> (pulls backups over SSH).
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_root

STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITES_DIR="${STACK_STATE_DIR:-/etc/wp-hosting}/sites"
BACKUP_ROOT="/var/backups/missiria-auto"
MYSQL_BIN="$(command -v mariadb || command -v mysql)"

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

DOMAIN="${1:-}"; [[ -n "$DOMAIN" && "$DOMAIN" != -* ]] || usage
shift
BACKUP=""; SOURCE="root@81.17.98.31"; WANT_SSL=0; DRY=0; FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup)  BACKUP="${2:?}"; shift 2 ;;
    --source)  SOURCE="${2:?}"; shift 2 ;;
    --ssl)     WANT_SSL=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --force)   FORCE=1; shift ;;
    *) err "unknown option: $1"; usage ;;
  esac
done
DOMAIN="${DOMAIN,,}"; DOMAIN="${DOMAIN#www.}"

SSH="ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new $SOURCE"

section "Migrate $DOMAIN  (source: $SOURCE)"

# --- 1. preflight -----------------------------------------------------------
$SSH true 2>/dev/null || die "cannot SSH $SOURCE — authorise this host's key in its ~/.ssh/authorized_keys first"

if [[ -z "$BACKUP" ]]; then
  BACKUP="$($SSH "ls -1dt $BACKUP_ROOT/*/ 2>/dev/null | while read -r d; do [ -f \"\${d}${DOMAIN}/backup-info.txt\" ] && { basename \"\$d\"; break; }; done")"
  [[ -n "$BACKUP" ]] || die "no backup found for $DOMAIN under $BACKUP_ROOT on $SOURCE"
fi
REMOTE_DIR="$BACKUP_ROOT/$BACKUP/$DOMAIN"
$SSH "test -f '$REMOTE_DIR/backup-info.txt'" || die "backup-info.txt missing at $REMOTE_DIR"

if [[ -f "$SITES_DIR/$DOMAIN.env" && $FORCE -ne 1 ]]; then
  die "tenant $DOMAIN already exists — pass --force to overwrite its DB/files"
fi

# --- 2. read backup-info ----------------------------------------------------
INFO="$($SSH "cat '$REMOTE_DIR/backup-info.txt'")"
get() { printf '%s\n' "$INFO" | grep -m1 "^$1=" | cut -d= -f2-; }
DB_NAME="$(get database_name)"
SITE_ROOT="$(get site_root)"
SLUG="$(basename "$SITE_ROOT")"
FILES_ARC="$(get files_archive)"
DB_ARC="$(get database_archive)"
[[ -n "$DB_ARC" && -n "$FILES_ARC" && -n "$SLUG" ]] || die "backup-info.txt incomplete"

log "backup   : $BACKUP"
log "db name  : $DB_NAME"
log "slug     : $SLUG   (files under ${SLUG}/ in the archive)"
log "files    : $FILES_ARC"

if [[ $DRY -eq 1 ]]; then
  section "DRY RUN"
  log "would: stage backup → provision tenant ($([[ $WANT_SSL -eq 1 ]] && echo ssl || echo no-ssl)) → overlay wp-content → import DB (prefix from dump) → salts/blog_public/redis/notify → health"
  exit 0
fi

# --- 3. stage backup onto this host (stream over SSH; old VPS read-only) -----
section "1/6 Stage backup"
WORK="/var/www/$DOMAIN/.migrate"
install -d -m 0700 "$WORK"
log "pulling files.tar.gz ($($SSH "du -h '$FILES_ARC' | cut -f1"))…"
$SSH "cat '$FILES_ARC'" > "$WORK/files.tar.gz"
$SSH "cat '$DB_ARC'"    > "$WORK/db.sql.gz"
ok "staged $(du -h "$WORK/files.tar.gz" | cut -f1) files + $(du -h "$WORK/db.sql.gz" | cut -f1) db"

# --- 4. provision tenant ----------------------------------------------------
section "2/6 Provision tenant"
if [[ -f "$SITES_DIR/$DOMAIN.env" ]]; then
  ok "tenant exists (reusing)"
else
  cargs=("$DOMAIN"); [[ $WANT_SSL -eq 1 ]] || cargs+=(--no-ssl)
  "$STACK/create-site.sh" "${cargs[@]}" || die "create-site failed"
fi
# shellcheck disable=SC1090
source "$SITES_DIR/$DOMAIN.env"   # SYSUSER DOCROOT DB_NAME DB_USER DB_PASS …
run_as() { sudo -u "$SYSUSER" -H env PATH="/usr/local/bin:/usr/bin:/bin" wp "$@" --path="$DOCROOT"; }

# --- 5. files (wp-content only; keep tenant core + wp-config) ----------------
section "3/6 Files (wp-content)"
rm -rf "$WORK/extract"; mkdir -p "$WORK/extract"
tar xzf "$WORK/files.tar.gz" -C "$WORK/extract"
SRC_WPC="$WORK/extract/$SLUG/wp-content"
[[ -d "$SRC_WPC" ]] || SRC_WPC="$(find "$WORK/extract" -maxdepth 2 -type d -name wp-content | head -1)"
[[ -d "$SRC_WPC" ]] || die "wp-content not found in archive"
rsync -a --exclude='cache/' --exclude='upgrade/' --exclude='upgrade-temp-backup/' \
      "$SRC_WPC/" "$DOCROOT/wp-content/"
chown -R "$SYSUSER":"$SYSUSER" "$DOCROOT/wp-content"
ok "wp-content synced ($(du -sh "$DOCROOT/wp-content/uploads" 2>/dev/null | cut -f1) uploads)"

# --- 6. database ------------------------------------------------------------
section "4/6 Database"
PREFIX="$(zcat "$WORK/db.sql.gz" | grep -m1 -oE 'CREATE TABLE `[A-Za-z0-9_]+options`' | sed -E 's/CREATE TABLE `(.*)options`/\1/')"
[[ -n "$PREFIX" ]] || die "could not detect table prefix from dump"
SRC_URL="$(zcat "$WORK/db.sql.gz" | grep -m1 -oE "'siteurl','https?://[^']+'" | sed -E "s/'siteurl','([^']+)'/\1/")"
log "prefix: $PREFIX   siteurl(dump): ${SRC_URL:-?}"
run_as config set table_prefix "$PREFIX" >/dev/null
run_as db reset --yes >/dev/null 2>&1 || warn "wp db reset failed (continuing)"
zcat "$WORK/db.sql.gz" | "$MYSQL_BIN" --user="$DB_USER" --password="$DB_PASS" "$DB_NAME"
ok "imported into $DB_NAME ($("$MYSQL_BIN" --user="$DB_USER" --password="$DB_PASS" "$DB_NAME" -N -e 'SHOW TABLES' | wc -l) tables)"

# same-domain migration → rewrite only if the dump host differs from this domain
SRC_HOST="${SRC_URL#*://}"; SRC_HOST="${SRC_HOST%%/*}"; SRC_BARE="${SRC_HOST#www.}"
if [[ -n "$SRC_BARE" && "$SRC_BARE" != "$DOMAIN" ]]; then
  section "5/6 URL rewrite ($SRC_BARE → $DOMAIN)"
  run_as search-replace "www.$SRC_BARE" "www.$DOMAIN" --all-tables --report-changed-only
  run_as search-replace "$SRC_BARE" "$DOMAIN" --all-tables --report-changed-only
else
  section "5/6 URL rewrite"
  log "same domain — no rewrite"
fi
ok "siteurl: $(run_as option get siteurl 2>/dev/null)"

# --- 7. post-import hardening ----------------------------------------------
section "6/6 Finalize"
run_as config shuffle-salts >/dev/null 2>&1 || true
run_as option update blog_public 1 >/dev/null 2>&1 && ok "blog_public=1 (indexable)"
run_as plugin install redis-cache --activate >/dev/null 2>&1 || true
run_as redis enable >/dev/null 2>&1 && ok "redis object cache on" || warn "redis enable deferred"

# MISSIRIA Telegram + SMTP constants (shared secrets from the notify conf)
NOTIFY_CONF="${STACK_STATE_DIR:-/etc/wp-hosting}/missiria-notify.conf"
if [[ -f "$NOTIFY_CONF" ]]; then
  # shellcheck disable=SC1090
  source "$NOTIFY_CONF"
  cfg() { run_as config set "$@" >/dev/null 2>&1; }
  [[ -n "${TG_BOT_TOKEN:-}" ]] && cfg MISSIRIA_TG_BOT_TOKEN "$TG_BOT_TOKEN" --type=constant
  [[ -n "${TG_CHAT_ID:-}"   ]] && cfg MISSIRIA_TG_CHAT_ID   "$TG_CHAT_ID"   --type=constant
  cfg MISSIRIA_SMTP_HOST   "${SMTP_HOST:-localhost}" --type=constant
  cfg MISSIRIA_SMTP_PORT   "${SMTP_PORT:-25}"        --type=constant --raw
  cfg MISSIRIA_SMTP_SECURE "${SMTP_SECURE:-}"        --type=constant
  cfg MISSIRIA_SMTP_AUTH   "${SMTP_AUTH:-false}"     --type=constant --raw
  cfg MISSIRIA_SMTP_USERNAME   "contact@$DOMAIN" --type=constant
  cfg MISSIRIA_SMTP_FROM_EMAIL "contact@$DOMAIN" --type=constant
  cfg MISSIRIA_SMTP_FROM_NAME  "$(run_as option get blogname 2>/dev/null || echo "$DOMAIN")" --type=constant
  ok "MISSIRIA notify constants written"
else
  warn "no $NOTIFY_CONF — skipped Telegram/SMTP constants"
fi

run_as rewrite flush >/dev/null 2>&1 || true
run_as cache flush >/dev/null 2>&1 || true
find "${FASTCGI_CACHE_ROOT:-/var/cache/nginx/fastcgi}" -type f -delete 2>/dev/null || true

# --- health -----------------------------------------------------------------
section "Health"
port=$([[ $WANT_SSL -eq 1 ]] && echo 443 || echo 80)
scheme=$([[ $WANT_SSL -eq 1 ]] && echo https || echo http)
code="$(curl -sk -o /dev/null -w '%{http_code}' --resolve "www.$DOMAIN:$port:127.0.0.1" "$scheme://www.$DOMAIN/" || true)"
[[ "$code" =~ ^(200|301|302)$ ]] && ok "origin www.$DOMAIN -> $code" || warn "origin www.$DOMAIN -> $code"

section "Done — $DOMAIN migrated to paradiso"
log "Public site still served by the OLD VPS via Cloudflare (no DNS change made)."
log "Cutover when ready:"
log "  1) Cloudflare: point A/AAAA for $DOMAIN + www → 109.199.102.152"
log "  2) sudo $STACK/create-site.sh $DOMAIN     # issues the LE cert + finishes TLS vhost"
log "Creds: $SITES_DIR/$DOMAIN.env   ·   staged backup: $WORK"

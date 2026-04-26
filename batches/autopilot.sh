#!/usr/bin/env bash

# ============================================================
# AUTO-PILOT v3 — WEBSITE LAUNCHER
# Phase 1: collect ALL inputs  →  Phase 2: execute silently
# Covers: FILES / NGINX / CERTBOT / DB / EMAIL / VARNISH / AUDIT+DNS
# ============================================================

if [[ "$EUID" -ne 0 ]]; then
    printf '\033[0;31m❌  Please run as root (or use sudo).\033[0m\n'
    exit 1
fi

set -o pipefail

# ── Colors ───────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── MySQL settings ───────────────────────────────────────────
DB_USER="${DB_USER:-missiria}"
DB_PASS="${DB_PASS:-}"
MYSQL_ADMIN_USER="${MYSQL_ADMIN_USER:-root}"
MYSQL_ADMIN_PASS="${MYSQL_ADMIN_PASS:-}"
MYSQL_BIN="${MYSQL_BIN:-mysql}"
MYSQLDUMP_BIN="${MYSQLDUMP_BIN:-mysqldump}"

# ── All intake variables (set during Phase 1, used in Phase 2) ─
MODE=""             # new | copy
DOMAIN=""
WEB_ROOT=""

SRC_DOMAIN=""       # COPY only
SRC_WEB_ROOT=""     # COPY only
SRC_DB=""           # COPY only

DB_NAME=""
DB_DUMP=""          # NEW only: optional import dump
WP_PREFIX="wp_"     # COPY only: URL migration prefix
OLD_URL=""          # COPY only
NEW_URL=""          # COPY only

EMAIL_PREFIX="contact"
EMAIL_FULL_USER=""

ENABLE_VARNISH="n"
PHP_VER="8.3"
SKIP_CERTBOT="n"

# ============================================================
# HELPERS
# ============================================================

print_header() {
    clear
    printf '%b\n' "${CYAN}______  ____________________________________________________${NC}"
    printf '%b\n' "${CYAN}___   |/  /___  _/_  ___/_  ___/___  _/__  __ \\___  _/__    |${NC}"
    printf '%b\n' "${CYAN}__  /|_/ / __  / _____ \\_____ \\ __  / __  /_/ /__  / __  /| |${NC}"
    printf '%b\n' "${CYAN}_  /  / / __/ /  ____/ /____/ /__/ /  _  _, _/__/ /  _  ___ |${NC}"
    printf '%b\n' "${CYAN}/_/  /_/  /___/  /____/ /____/ /___/  /_/ |_| /___/  /_/  |_|${NC}"
    printf '%b\n' "${CYAN}                                                             v3${NC}"
    printf '%b\n' "${GREEN}${BOLD} AUTO-PILOT — WEBSITE LAUNCHER${NC}"
    echo ""
}

section() {
    echo ""
    printf '%b\n' "${BLUE}════════════════════════════════════════════════════════════${NC}"
    printf '%b\n' "${BLUE}  STEP $1 — $2${NC}"
    printf '%b\n' "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo ""
}

ok()   { printf '%b\n' "${GREEN}  ✅  $*${NC}"; }
warn() { printf '%b\n' "${YELLOW}  ⚠️   $*${NC}"; }
fail() { printf '%b\n' "${RED}  ❌  $*${NC}"; }
info() { printf '%b\n' "${CYAN}  ℹ️   $*${NC}"; }
ask()  { printf '%b' "  ${YELLOW}▶ $* ${NC}"; }

confirm() {
    local ans
    read -r -p "$(printf '%b' "  ${YELLOW}${1:-Proceed?} [y/N]: ${NC}")" ans
    [[ "$ans" == "y" || "$ans" == "Y" ]]
}

sql_escape_literal() {
    local v="$1"; v="${v//\\/\\\\}"; v="${v//\'/\'\'}"; printf '%s' "$v"
}
quote_identifier() {
    local v="$1"; v="${v//\`/\`\`}"; printf '`%s`' "$v"
}
mysql_exec()     { MYSQL_PWD="$DB_PASS"       "$MYSQL_BIN" -u "$DB_USER"       "$@"; }
mysql_exec_db()  { local db="$1"; shift; MYSQL_PWD="$DB_PASS"       "$MYSQL_BIN" -u "$DB_USER"       -D "$db" "$@"; }
mysql_admin()    { MYSQL_PWD="$MYSQL_ADMIN_PASS" "$MYSQL_BIN" -u "$MYSQL_ADMIN_USER" "$@"; }
mysql_admin_db() { local db="$1"; shift; MYSQL_PWD="$MYSQL_ADMIN_PASS" "$MYSQL_BIN" -u "$MYSQL_ADMIN_USER" -D "$db" "$@"; }
database_exists() {
    local esc result
    esc="$(sql_escape_literal "$1")"
    result="$(mysql_admin -N -s -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${esc}' LIMIT 1;" 2>/dev/null || true)"
    [[ "$result" == "$1" ]]
}

# ============================================================
# PHASE 1 — INTAKE  (questions only, zero execution)
# ============================================================

intake_mode() {
    echo ""
    printf '%b\n' "  ${BOLD}┌─────────────────────────────────────────────────────┐${NC}"
    printf '%b\n' "  ${BOLD}│                                                     │${NC}"
    printf '%b\n' "  ${BOLD}│   ${BLUE}[N]${NC}${BOLD}  NEW website   — blank setup from scratch    │${NC}"
    printf '%b\n' "  ${BOLD}│   ${BLUE}[C]${NC}${BOLD}  COPY website  — duplicate / migrate a site  │${NC}"
    printf '%b\n' "  ${BOLD}│                                                     │${NC}"
    printf '%b\n' "  ${BOLD}└─────────────────────────────────────────────────────┘${NC}"
    echo ""

    while true; do
        ask "Choice [N/C]:"
        read -r choice
        case "${choice,,}" in
            n|new)  MODE="new";  break ;;
            c|copy) MODE="copy"; break ;;
            *) warn "Type N for New or C for Copy." ;;
        esac
    done
}

intake_domain() {
    echo ""
    printf '%b\n' "  ${CYAN}── TARGET DOMAIN ─────────────────────────────────────${NC}"

    while [[ -z "$DOMAIN" ]]; do
        ask "New domain (e.g., example.com):"
        read -r DOMAIN
        DOMAIN="${DOMAIN#www.}"
        DOMAIN="${DOMAIN%/}"
        [[ -z "$DOMAIN" ]] && warn "Domain cannot be empty."
    done

    ask "Web root [/var/www/MISSIRIA/$DOMAIN]:"
    read -r WEB_ROOT
    WEB_ROOT="${WEB_ROOT:-/var/www/MISSIRIA/$DOMAIN}"
}

intake_copy_source() {
    echo ""
    printf '%b\n' "  ${CYAN}── SOURCE SITE ───────────────────────────────────────${NC}"

    # Source domain — list existing Nginx configs
    local -a configs=()
    while IFS= read -r f; do
        local bname; bname="$(basename "$f")"
        [[ "$bname" != "default" && "$bname" != "$DOMAIN" ]] && configs+=("$bname")
    done < <(find /etc/nginx/sites-available/ -maxdepth 1 \( -type f -o -type l \) 2>/dev/null | sort)

    if ((${#configs[@]} > 0)); then
        echo ""
        info "Existing Nginx configs (copy from):"
        for i in "${!configs[@]}"; do
            printf '%b\n' "    ${BLUE}[$((i+1))]${NC} ${configs[$i]}"
        done
        echo ""
        ask "Select source domain number (or leave blank to type manually):"
        read -r idx_choice
        if [[ "$idx_choice" =~ ^[0-9]+$ ]]; then
            local idx=$((idx_choice - 1))
            ((idx >= 0 && idx < ${#configs[@]})) && SRC_DOMAIN="${configs[$idx]}"
        fi
    fi

    if [[ -z "$SRC_DOMAIN" ]]; then
        ask "Source domain (copy Nginx config from):"
        read -r SRC_DOMAIN
    fi
    info "Source domain: $SRC_DOMAIN"

    # Source web root
    local default_src="/var/www/MISSIRIA/$SRC_DOMAIN"
    ask "Source web root [$default_src]:"
    read -r SRC_WEB_ROOT
    SRC_WEB_ROOT="${SRC_WEB_ROOT:-$default_src}"

    # Source database — list existing DBs
    local -a db_list=()
    while IFS= read -r row; do
        [[ -n "$row" ]] && db_list+=("$row")
    done < <(mysql_admin -N -s -e "SHOW DATABASES;" 2>/dev/null | grep -vE '^(information_schema|performance_schema|mysql|sys)$')

    if ((${#db_list[@]} > 0)); then
        echo ""
        info "Available databases to clone:"
        for i in "${!db_list[@]}"; do
            printf '%b\n' "    ${BLUE}[$((i+1))]${NC} ${db_list[$i]}"
        done
        echo ""
        ask "Select source DB number:"
        read -r idx_choice
        if [[ "$idx_choice" =~ ^[0-9]+$ ]]; then
            local idx=$((idx_choice - 1))
            ((idx >= 0 && idx < ${#db_list[@]})) && SRC_DB="${db_list[$idx]}"
        fi
    fi

    if [[ -z "$SRC_DB" ]]; then
        ask "Source database name to clone:"
        read -r SRC_DB
    fi
    info "Source DB: $SRC_DB"
}

intake_database() {
    echo ""
    printf '%b\n' "  ${CYAN}── DATABASE ──────────────────────────────────────────${NC}"

    local suggested_db="wp_$(echo "$DOMAIN" | tr '.-' '_')"
    ask "New database name [$suggested_db]:"
    read -r DB_NAME
    DB_NAME="${DB_NAME:-$suggested_db}"
    DB_NAME="$(echo "$DB_NAME" | tr '.-' '_')"
    info "Database name: $DB_NAME"

    if [[ "$MODE" == "new" ]]; then
        ask "SQL dump to import after creation (blank = empty DB):"
        read -r DB_DUMP
    else
        ask "WordPress table prefix [wp_]:"
        read -r WP_PREFIX
        WP_PREFIX="${WP_PREFIX:-wp_}"

        ask "FROM URL — source site [https://$SRC_DOMAIN]:"
        read -r OLD_URL
        OLD_URL="${OLD_URL:-https://$SRC_DOMAIN}"

        ask "TO URL   — new site   [https://$DOMAIN]:"
        read -r NEW_URL
        NEW_URL="${NEW_URL:-https://$DOMAIN}"
    fi
}

intake_email() {
    echo ""
    printf '%b\n' "  ${CYAN}── EMAIL ─────────────────────────────────────────────${NC}"

    ask "Email prefix [contact]:"
    read -r EMAIL_PREFIX
    EMAIL_PREFIX="${EMAIL_PREFIX:-contact}"

    local site_name site_clean
    site_name="$(echo "$DOMAIN" | cut -d'.' -f1)"
    site_clean="$(echo "$site_name" | tr '-' '_')"
    EMAIL_FULL_USER="${EMAIL_PREFIX}_${site_clean}"

    info "Will create: ${EMAIL_PREFIX}@${DOMAIN}  →  system user: ${EMAIL_FULL_USER}"
}

intake_options() {
    echo ""
    printf '%b\n' "  ${CYAN}── OPTIONS ───────────────────────────────────────────${NC}"

    ask "Enable Varnish cache? [y/N]:"
    read -r ENABLE_VARNISH
    ENABLE_VARNISH="${ENABLE_VARNISH:-n}"
    if [[ "${ENABLE_VARNISH,,}" == "y" ]]; then
        ask "PHP version for Nginx backend [8.3]:"
        read -r PHP_VER
        PHP_VER="${PHP_VER:-8.3}"
    fi

    ask "Skip Certbot SSL? (useful for local/dev) [y/N]:"
    read -r SKIP_CERTBOT
    SKIP_CERTBOT="${SKIP_CERTBOT:-n}"
}

print_summary() {
    echo ""
    printf '%b\n' "${BLUE}════════════════════════════════════════════════════════════${NC}"
    printf '%b\n' "${BLUE}${BOLD}  SUMMARY — REVIEW BEFORE LAUNCH${NC}"
    printf '%b\n' "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo ""
    printf '    Mode          : %b%s%b\n' "${BOLD}" "${MODE^^}" "${NC}"
    printf '    Domain        : %s\n'     "$DOMAIN"
    printf '    Web root      : %s\n'     "$WEB_ROOT"

    if [[ "$MODE" == "copy" ]]; then
        echo ""
        printf '    Source domain : %s\n' "$SRC_DOMAIN"
        printf '    Source root   : %s\n' "$SRC_WEB_ROOT"
        printf '    Source DB     : %s\n' "$SRC_DB"
    fi

    echo ""
    printf '    Database      : %s\n' "$DB_NAME"
    [[ "$MODE" == "new" && -n "$DB_DUMP" ]] && printf '    DB dump       : %s\n' "$DB_DUMP"
    if [[ "$MODE" == "copy" ]]; then
        printf '    URL migrate   : %s  →  %s\n' "$OLD_URL" "$NEW_URL"
        printf '    WP prefix     : %s\n' "$WP_PREFIX"
    fi

    echo ""
    printf '    Email         : %s@%s\n' "$EMAIL_PREFIX" "$DOMAIN"
    printf '    System user   : %s\n'    "$EMAIL_FULL_USER"

    echo ""
    printf '    Varnish       : %s\n' "${ENABLE_VARNISH,,}"
    [[ "${ENABLE_VARNISH,,}" == "y" ]] && printf '    PHP version   : %s\n' "$PHP_VER"
    printf '    Certbot SSL   : %s\n' "$( [[ "${SKIP_CERTBOT,,}" == "y" ]] && echo "SKIP" || echo "YES")"

    echo ""
    printf '%b\n' "  ${CYAN}Execution plan:${NC}"
    printf '%b\n' "  ${BLUE}1/7${NC} FILES   — $( [[ "$MODE" == "copy" ]] && echo "rsync $SRC_WEB_ROOT → $WEB_ROOT + update wp-config" || echo "create $WEB_ROOT")"
    printf '%b\n' "  ${BLUE}2/7${NC} NGINX   — $( [[ "$MODE" == "copy" ]] && echo "copy & adapt config from $SRC_DOMAIN" || echo "new config for $DOMAIN")"
    printf '%b\n' "  ${BLUE}3/7${NC} CERTBOT — $( [[ "${SKIP_CERTBOT,,}" == "y" ]] && echo "SKIPPED" || echo "SSL for $DOMAIN + www.$DOMAIN")"
    printf '%b\n' "  ${BLUE}4/7${NC} DB      — $( [[ "$MODE" == "copy" ]] && echo "clone $SRC_DB → $DB_NAME + URL migration" || echo "create $DB_NAME$( [[ -n "$DB_DUMP" ]] && echo " + import dump" || echo " (empty)")")"
    printf '%b\n' "  ${BLUE}5/7${NC} EMAIL   — ${EMAIL_PREFIX}@${DOMAIN}  (user: $EMAIL_FULL_USER)"
    printf '%b\n' "  ${BLUE}6/7${NC} VARNISH — $( [[ "${ENABLE_VARNISH,,}" == "y" ]] && echo "activate (PHP $PHP_VER backend)" || echo "SKIPPED")"
    printf '%b\n' "  ${BLUE}7/7${NC} AUDIT   — DNS / Nginx / SSL / HTTP / Files / DB / Email / Varnish"
    echo ""
    printf '%b\n' "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ============================================================
# PHASE 2 — EXECUTION  (no reads, no prompts)
# ============================================================

exec_files() {
    section "1/7" "FILES"

    if [[ "$MODE" == "new" ]]; then
        info "Creating web root: $WEB_ROOT"
        mkdir -p "$WEB_ROOT"
        chown -R www-data:www-data "$WEB_ROOT"
        chmod -R 755 "$WEB_ROOT"
        ok "Web root ready: $WEB_ROOT"
    else
        if [[ ! -d "$SRC_WEB_ROOT" ]]; then
            fail "Source web root not found: $SRC_WEB_ROOT"
            return
        fi

        info "Creating target: $WEB_ROOT"
        mkdir -p "$WEB_ROOT"

        info "Rsyncing: $SRC_WEB_ROOT → $WEB_ROOT ..."
        if rsync -a --delete "$SRC_WEB_ROOT/" "$WEB_ROOT/"; then
            ok "Files copied."
        else
            fail "rsync failed — check manually."
            return
        fi

        chown -R www-data:www-data "$WEB_ROOT"
        chmod -R 755 "$WEB_ROOT"
        ok "Ownership set: www-data:www-data"

        local wp_config="$WEB_ROOT/wp-config.php"
        if [[ -f "$wp_config" ]]; then
            info "Updating wp-config.php → DB_NAME=$DB_NAME ..."
            sed -i "s/define[[:space:]]*([[:space:]]*'DB_NAME'[[:space:]]*,[[:space:]]*'[^']*'/define('DB_NAME', '$DB_NAME'/" "$wp_config"
            ok "wp-config.php DB_NAME updated."
        fi
    fi
}

exec_nginx() {
    section "2/7" "NGINX"

    local avail="/etc/nginx/sites-available/$DOMAIN"
    local enabled="/etc/nginx/sites-enabled/$DOMAIN"

    if [[ "$MODE" == "new" ]]; then
        _nginx_write_new "$avail"
    else
        local src_conf="/etc/nginx/sites-available/$SRC_DOMAIN"
        if [[ -f "$src_conf" ]]; then
            info "Copying config: $SRC_DOMAIN → $DOMAIN ..."
            sed \
                -e "s|server_name [^;]*;|server_name $DOMAIN www.$DOMAIN;|g" \
                -e "s|root [^;]*;|root $WEB_ROOT;|g" \
                -e "s|/etc/letsencrypt/live/${SRC_DOMAIN}/|/etc/letsencrypt/live/${DOMAIN}/|g" \
                "$src_conf" > "$avail"
            ok "Config copied and adapted from $SRC_DOMAIN."
        else
            warn "Source config not found ($src_conf) — creating fresh config."
            _nginx_write_new "$avail"
        fi
    fi

    [[ -L "$enabled" || -f "$enabled" ]] && rm -f "$enabled"
    ln -s "$avail" "$enabled"

    info "Testing Nginx config..."
    if nginx -t 2>&1; then
        systemctl reload nginx
        ok "Nginx reloaded — $DOMAIN live on HTTP."
    else
        fail "Nginx config test FAILED — removing symlink."
        rm -f "$enabled"
    fi
}

_nginx_write_new() {
    local avail="$1"
    [[ -f "$avail" ]] && warn "Config already exists — overwriting."
    info "Writing: $avail"
    cat > "$avail" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;
    root $WEB_ROOT;
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF
    ok "Nginx config written."
}

exec_certbot() {
    section "3/7" "CERTBOT SSL"

    if [[ "${SKIP_CERTBOT,,}" == "y" ]]; then
        warn "Certbot SKIPPED (as requested)."
        return
    fi

    if ! command -v certbot &>/dev/null; then
        warn "certbot not found. Install: apt install certbot python3-certbot-nginx"
        warn "Then run: certbot --nginx -d $DOMAIN -d www.$DOMAIN"
        return
    fi

    info "Issuing SSL for $DOMAIN + www.$DOMAIN ..."
    if certbot --nginx -d "$DOMAIN" -d "www.$DOMAIN" --redirect; then
        ok "SSL certificate issued and Nginx updated with HTTPS redirect!"
    else
        warn "Certbot had issues — run manually: certbot --nginx -d $DOMAIN -d www.$DOMAIN"
    fi
}

exec_database() {
    section "4/7" "DATABASE"

    local db_quoted
    db_quoted="$(quote_identifier "$DB_NAME")"

    if [[ "$MODE" == "new" ]]; then
        _db_create_new "$db_quoted"
    else
        _db_clone "$db_quoted"
    fi
}

_db_create_new() {
    local db_quoted="$1"

    if database_exists "$DB_NAME"; then
        warn "Database '$DB_NAME' already exists — skipping creation."
    else
        local db_user_esc; db_user_esc="$(sql_escape_literal "$DB_USER")"
        if mysql_admin <<EOF
CREATE DATABASE ${db_quoted} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON ${db_quoted}.* TO '${db_user_esc}'@'localhost';
FLUSH PRIVILEGES;
EOF
        then
            ok "Database '$DB_NAME' created and privileges granted to '$DB_USER'@localhost."
        else
            fail "Failed to create database '$DB_NAME'."
            return
        fi
    fi

    if [[ -n "$DB_DUMP" && -f "$DB_DUMP" ]]; then
        info "Importing '$DB_DUMP' into '$DB_NAME' ..."
        mysql_exec_db "$DB_NAME" < "$DB_DUMP" && ok "Import complete." || fail "Import failed."
    elif [[ -n "$DB_DUMP" ]]; then
        warn "Dump file not found: $DB_DUMP — skipped."
    else
        info "Empty database (no dump specified)."
    fi
}

_db_clone() {
    local db_quoted="$1"

    if [[ -z "$SRC_DB" ]]; then
        warn "No source DB specified — creating empty DB."
        _db_create_new "$db_quoted"
        return
    fi

    local tmp_dump="/tmp/autopilot_${SRC_DB}_$(date +%s).sql"
    info "Exporting '$SRC_DB' ..."
    if ! MYSQL_PWD="$DB_PASS" "$MYSQLDUMP_BIN" -u "$DB_USER" "$SRC_DB" > "$tmp_dump"; then
        fail "Export of '$SRC_DB' failed."
        return
    fi
    ok "Exported → $tmp_dump"

    if database_exists "$DB_NAME"; then
        warn "Database '$DB_NAME' exists — dropping and recreating."
        mysql_admin -e "DROP DATABASE ${db_quoted};"
    fi

    local db_user_esc; db_user_esc="$(sql_escape_literal "$DB_USER")"
    if ! mysql_admin <<EOF
CREATE DATABASE ${db_quoted} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON ${db_quoted}.* TO '${db_user_esc}'@'localhost';
FLUSH PRIVILEGES;
EOF
    then
        fail "Failed to create database '$DB_NAME'."
        rm -f "$tmp_dump"
        return
    fi

    info "Importing into '$DB_NAME' ..."
    if mysql_exec_db "$DB_NAME" < "$tmp_dump"; then
        ok "Clone complete!"
    else
        fail "Import failed."
        rm -f "$tmp_dump"
        return
    fi
    rm -f "$tmp_dump"

    if [[ -n "$OLD_URL" && -n "$NEW_URL" ]]; then
        _db_migrate_urls
    else
        warn "URL migration skipped (no URLs provided)."
    fi
}

_db_migrate_urls() {
    local old_esc new_esc opts posts postmeta rows
    old_esc="$(sql_escape_literal "$OLD_URL")"
    new_esc="$(sql_escape_literal "$NEW_URL")"
    opts="$(quote_identifier "${WP_PREFIX}options")"
    posts="$(quote_identifier "${WP_PREFIX}posts")"
    postmeta="$(quote_identifier "${WP_PREFIX}postmeta")"

    info "URL migration: $OLD_URL  →  $NEW_URL"

    rows="$(mysql_exec_db "$DB_NAME" -N -s -e "
        UPDATE ${opts} SET option_value = REPLACE(option_value,'${old_esc}','${new_esc}')
        WHERE option_name IN ('home','siteurl') AND INSTR(option_value,'${old_esc}') > 0;
        SELECT ROW_COUNT();
    " | tail -n1)"
    info "  options (home/siteurl) : ${rows:-0} row(s)"

    rows="$(mysql_exec_db "$DB_NAME" -N -s -e "
        UPDATE ${posts} SET guid = REPLACE(guid,'${old_esc}','${new_esc}')
        WHERE INSTR(guid,'${old_esc}') > 0;
        SELECT ROW_COUNT();
    " | tail -n1)"
    info "  posts.guid             : ${rows:-0} row(s)"

    rows="$(mysql_exec_db "$DB_NAME" -N -s -e "
        UPDATE ${posts} SET post_content = REPLACE(post_content,'${old_esc}','${new_esc}')
        WHERE INSTR(post_content,'${old_esc}') > 0;
        SELECT ROW_COUNT();
    " | tail -n1)"
    info "  posts.post_content     : ${rows:-0} row(s)"

    rows="$(mysql_exec_db "$DB_NAME" -N -s -e "
        UPDATE ${postmeta} SET meta_value = REPLACE(meta_value,'${old_esc}','${new_esc}')
        WHERE meta_value NOT LIKE 'a:%' AND meta_value NOT LIKE 'O:%'
          AND INSTR(meta_value,'${old_esc}') > 0;
        SELECT ROW_COUNT();
    " | tail -n1)"
    info "  postmeta.meta_value    : ${rows:-0} row(s)"

    ok "URL migration complete."
}

exec_email() {
    section "5/7" "EMAIL"

    local email_addr="${EMAIL_PREFIX}@${DOMAIN}"
    local home_dir="/home/$EMAIL_FULL_USER"
    local maildir="$home_dir/Maildir"

    info "Creating: $email_addr  →  $EMAIL_FULL_USER"

    if id "$EMAIL_FULL_USER" &>/dev/null; then
        warn "System user '$EMAIL_FULL_USER' already exists."
    else
        if adduser --disabled-password --gecos "" "$EMAIL_FULL_USER"; then
            ok "User created."
        else
            fail "Failed to create user '$EMAIL_FULL_USER'."
            return
        fi
    fi

    if [[ ! -d "$maildir" ]]; then
        mkdir -p "$maildir"/{cur,new,tmp}
        ok "Maildir created: $maildir"
    else
        warn "Maildir already exists."
    fi
    chown -R "$EMAIL_FULL_USER:$EMAIL_FULL_USER" "$home_dir"
    ok "Ownership set: $EMAIL_FULL_USER:$EMAIL_FULL_USER"

    if grep -q "^${email_addr} " /etc/postfix/virtual 2>/dev/null; then
        warn "Postfix alias already exists for $email_addr"
    else
        echo "$email_addr $EMAIL_FULL_USER" >> /etc/postfix/virtual
        postmap /etc/postfix/virtual
        ok "Postfix alias added."
    fi

    systemctl reload postfix && ok "Postfix reloaded." || warn "Postfix reload failed."
}

exec_varnish() {
    section "6/7" "VARNISH"

    if [[ "${ENABLE_VARNISH,,}" != "y" ]]; then
        info "Varnish: SKIPPED."
        return
    fi

    if ! command -v varnishd &>/dev/null && ! systemctl list-units --type=service 2>/dev/null | grep -q varnish; then
        warn "Varnish not installed — skipping. Install: apt install varnish"
        return
    fi

    local avail="/etc/nginx/sites-available/$DOMAIN"
    local enabled="/etc/nginx/sites-enabled/$DOMAIN"

    info "Backing up current Nginx config → ${avail}.pre-varnish.bak"
    [[ -f "$avail" ]] && cp "$avail" "${avail}.pre-varnish.bak"

    info "Writing Varnish architecture (backend :8080, HTTPS → Varnish :6081) ..."
    cat > "$avail" <<EOF
# ── BACKEND (PHP on port 8080) ────────────────────────────
server {
    listen 8080;
    server_name $DOMAIN www.$DOMAIN;
    root $WEB_ROOT;
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht { deny all; }
}

# ── FRONT DOOR (HTTPS :443 → Varnish :6081) ──────────────
server {
    listen [::]:443 ssl;
    listen 443 ssl;
    server_name $DOMAIN www.$DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://127.0.0.1:6081;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port  443;
    }
}
EOF
    ok "Varnish Nginx config written."

    local wp_config="$WEB_ROOT/wp-config.php"
    if [[ -f "$wp_config" ]] && ! grep -q "HTTP_X_FORWARDED_PROTO" "$wp_config"; then
        local tmp="${wp_config}.varnish.tmp"
        awk '
            /^<\?php/ && !done {
                print; print ""
                print "if (isset($_SERVER['"'"'HTTP_X_FORWARDED_PROTO'"'"']) && strpos($_SERVER['"'"'HTTP_X_FORWARDED_PROTO'"'"'], '"'"'https'"'"') !== false) {"
                print "    $_SERVER['"'"'HTTPS'"'"'] = '"'"'on'"'"';"
                print "}"
                print "if (isset($_SERVER['"'"'HTTP_X_FORWARDED_HOST'"'"'])) {"
                print "    $_SERVER['"'"'HTTP_HOST'"'"'] = $_SERVER['"'"'HTTP_X_FORWARDED_HOST'"'"'];"
                print "}"
                print ""; done=1; next
            }
            1
        ' "$wp_config" > "$tmp" && mv "$tmp" "$wp_config"
        chown www-data:www-data "$wp_config"
        ok "Proxy snippet injected into wp-config.php"
    fi

    systemctl enable varnish 2>/dev/null || true
    systemctl restart varnish
    systemctl is-active --quiet varnish && ok "Varnish is running." || warn "Varnish may not be running — check: systemctl status varnish"

    [[ -L "$enabled" || -f "$enabled" ]] && rm -f "$enabled"
    ln -s "$avail" "$enabled"
    nginx -t 2>&1 && systemctl reload nginx && ok "Nginx reloaded with Varnish config."

    sleep 2
    local headers
    headers="$(curl -I -s --max-time 10 "https://$DOMAIN" 2>/dev/null || true)"
    if echo "$headers" | grep -iq 'x-varnish'; then
        ok "Varnish headers confirmed!"
        echo "$headers" | grep -i -E 'x-cache|age|x-varnish|via' || true
    else
        warn "Varnish headers not detected yet (SSL may not be ready)."
    fi
}

exec_audit() {
    section "7/7" "FULL AUDIT"

    local all_ok=1
    local email_addr="${EMAIL_PREFIX}@${DOMAIN}"
    local maildir="/home/$EMAIL_FULL_USER/Maildir"

    # ── DNS ──────────────────────────────────────────────────
    printf '%b\n' "\n${BOLD}  [DNS]${NC}"
    if command -v dig &>/dev/null; then
        local a_record
        a_record="$(dig +short A "$DOMAIN" 2>/dev/null | head -1)"
        if [[ -n "$a_record" ]]; then
            ok "A record : $DOMAIN → $a_record"
        else
            warn "No A record found for $DOMAIN (DNS propagation may be pending)"
        fi

        local mx_record
        mx_record="$(dig +short MX "$DOMAIN" 2>/dev/null | head -1)"
        [[ -n "$mx_record" ]] && ok "MX record: $DOMAIN → $mx_record" || warn "No MX record for $DOMAIN"

        local spf
        spf="$(dig +short TXT "$DOMAIN" 2>/dev/null | grep -i spf | head -1)"
        [[ -n "$spf" ]] && ok "SPF/TXT : $spf" || info "No SPF TXT record for $DOMAIN"

        local www_a
        www_a="$(dig +short A "www.$DOMAIN" 2>/dev/null | head -1)"
        [[ -n "$www_a" ]] && ok "www A   : www.$DOMAIN → $www_a" || warn "No A record for www.$DOMAIN"
    else
        info "dig not available — DNS skipped. Install: apt install dnsutils"
    fi

    # ── Nginx ────────────────────────────────────────────────
    printf '%b\n' "\n${BOLD}  [NGINX]${NC}"
    local avail="/etc/nginx/sites-available/$DOMAIN"
    local enabled="/etc/nginx/sites-enabled/$DOMAIN"
    [[ -f "$avail" ]]   && ok "Config exists : $avail"   || { fail "Config MISSING : $avail";   all_ok=0; }
    [[ -L "$enabled" ]] && ok "Symlink active: $enabled"  || { fail "Symlink MISSING: $enabled"; all_ok=0; }
    nginx -t 2>&1 | grep -q "successful" && ok "Nginx syntax OK" || { fail "Nginx config FAILED"; all_ok=0; }

    # ── SSL / Certbot ────────────────────────────────────────
    printf '%b\n' "\n${BOLD}  [SSL / CERTBOT]${NC}"
    if [[ "${SKIP_CERTBOT,,}" == "y" ]]; then
        info "Certbot was skipped."
    elif command -v certbot &>/dev/null; then
        if certbot certificates 2>/dev/null | grep -q "$DOMAIN"; then
            ok "SSL certificate: found for $DOMAIN"
            local expiry
            expiry="$(certbot certificates 2>/dev/null | grep -A8 "Domains:.*${DOMAIN}" | grep "Expiry Date" | awk '{print $3,$4}' | head -1)"
            [[ -n "$expiry" ]] && info "Expires: $expiry"
        else
            warn "No SSL cert for $DOMAIN — run: certbot --nginx -d $DOMAIN -d www.$DOMAIN"
            all_ok=0
        fi
    else
        warn "certbot not installed."
    fi

    # ── HTTP response ────────────────────────────────────────
    printf '%b\n' "\n${BOLD}  [HTTP RESPONSE]${NC}"
    local http_code
    http_code="$(curl -o /dev/null -s -w "%{http_code}" --max-time 10 "https://$DOMAIN" 2>/dev/null || echo "000")"
    if [[ "$http_code" =~ ^(200|301|302)$ ]]; then
        ok "HTTPS responds $http_code → https://$DOMAIN"
    else
        warn "HTTP $http_code — site may not be fully up yet (normal before WP install)."
    fi

    # ── Files ────────────────────────────────────────────────
    printf '%b\n' "\n${BOLD}  [FILES]${NC}"
    if [[ -d "$WEB_ROOT" ]]; then
        local file_count
        file_count="$(find "$WEB_ROOT" -maxdepth 1 | wc -l)"
        ok "Web root exists: $WEB_ROOT ($((file_count - 1)) item(s))"
        local owner
        owner="$(stat -c "%U:%G" "$WEB_ROOT" 2>/dev/null)"
        [[ "$owner" == "www-data:www-data" ]] && ok "Ownership: $owner" || warn "Ownership: $owner (expected www-data:www-data)"
    else
        fail "Web root MISSING: $WEB_ROOT"
        all_ok=0
    fi

    # ── Database ─────────────────────────────────────────────
    printf '%b\n' "\n${BOLD}  [DATABASE]${NC}"
    if database_exists "$DB_NAME"; then
        ok "Database: $DB_NAME — exists"
        local tbl_count
        tbl_count="$(mysql_exec -N -s -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$(sql_escape_literal "$DB_NAME")';" 2>/dev/null || echo "?")"
        info "Tables: $tbl_count"
    else
        fail "Database MISSING: $DB_NAME"
        all_ok=0
    fi

    # ── Email ────────────────────────────────────────────────
    printf '%b\n' "\n${BOLD}  [EMAIL]${NC}"
    id "$EMAIL_FULL_USER" &>/dev/null \
        && ok "System user  : $EMAIL_FULL_USER" \
        || { fail "User MISSING : $EMAIL_FULL_USER"; all_ok=0; }
    grep -q "^${email_addr} " /etc/postfix/virtual 2>/dev/null \
        && ok "Postfix alias: $email_addr → $EMAIL_FULL_USER" \
        || { fail "Alias MISSING: $email_addr"; all_ok=0; }
    if [[ -d "$maildir" ]]; then
        local mowner; mowner="$(stat -c "%U:%G" "$maildir" 2>/dev/null)"
        [[ "$mowner" == "$EMAIL_FULL_USER:$EMAIL_FULL_USER" ]] \
            && ok "Maildir      : $maildir ($mowner)" \
            || { warn "Maildir ownership: $mowner (expected $EMAIL_FULL_USER:$EMAIL_FULL_USER)"; all_ok=0; }
    else
        fail "Maildir MISSING: $maildir"
        all_ok=0
    fi

    # ── Varnish ──────────────────────────────────────────────
    printf '%b\n' "\n${BOLD}  [VARNISH]${NC}"
    if [[ "${ENABLE_VARNISH,,}" == "y" ]]; then
        systemctl is-active --quiet varnish 2>/dev/null \
            && ok "Varnish: running" \
            || { warn "Varnish: NOT running"; all_ok=0; }
        local wp_config="$WEB_ROOT/wp-config.php"
        if [[ -f "$wp_config" ]]; then
            grep -q "HTTP_X_FORWARDED_PROTO" "$wp_config" \
                && ok "Proxy snippet: present in wp-config.php" \
                || { warn "Proxy snippet MISSING from wp-config.php"; all_ok=0; }
        fi
    else
        info "Varnish: not configured for this site."
    fi

    # ── Final summary ────────────────────────────────────────
    echo ""
    printf '%b\n' "${BLUE}════════════════════════════════════════════════════════════${NC}"
    if [[ "$all_ok" == "1" ]]; then
        printf '%b\n' "${GREEN}${BOLD}  ✅  ALL CHECKS PASSED — $DOMAIN is ready!${NC}"
    else
        printf '%b\n' "${YELLOW}${BOLD}  ⚠️   SOME CHECKS NEED ATTENTION — see above.${NC}"
    fi
    printf '%b\n' "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ============================================================
# MAIN
# ============================================================

main() {
    print_header

    # ── PHASE 1: INTAKE ──────────────────────────────────────
    printf '%b\n' "${CYAN}${BOLD}  ╔══════════════════════════════════════════════════╗${NC}"
    printf '%b\n' "${CYAN}${BOLD}  ║  PHASE 1 — CONFIGURATION                        ║${NC}"
    printf '%b\n' "${CYAN}${BOLD}  ║  Answer all questions. Execution starts after.  ║${NC}"
    printf '%b\n' "${CYAN}${BOLD}  ╚══════════════════════════════════════════════════╝${NC}"

    intake_mode
    intake_domain
    [[ "$MODE" == "copy" ]] && intake_copy_source
    intake_database
    intake_email
    intake_options

    # ── SUMMARY & CONFIRM ─────────────────────────────────────
    print_summary

    if ! confirm "Launch now? All steps will run without further prompts."; then
        echo "  Cancelled."
        exit 0
    fi

    # ── PHASE 2: EXECUTION ───────────────────────────────────
    echo ""
    printf '%b\n' "${CYAN}${BOLD}  ╔══════════════════════════════════════════════════╗${NC}"
    printf '%b\n' "${CYAN}${BOLD}  ║  PHASE 2 — EXECUTION                            ║${NC}"
    printf '%b\n' "${CYAN}${BOLD}  ╚══════════════════════════════════════════════════╝${NC}"

    exec_files
    exec_nginx
    exec_certbot
    exec_database
    exec_email
    exec_varnish
    exec_audit

    printf '%b\n' "${GREEN}${BOLD}  🎉  Auto-pilot complete → $DOMAIN${NC}"
    echo ""
}

main "$@"

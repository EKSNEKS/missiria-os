#!/bin/bash

# ============================================================
# AUTO-PILOT — NEW WEBSITE LAUNCHER
# Automates: Nginx + Certbot → MySQL → Email → Varnish → Audit
# ============================================================

if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m❌ Please run as root (or use sudo).\033[0m"
    exit 1
fi

set -o pipefail

# ── Colors ──────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── DB settings (mirrors db-manager.sh) ─────────────────────
DB_USER="${DB_USER:-root}"
MYSQL_BIN="${MYSQL_BIN:-mysql}"
MYSQLDUMP_BIN="${MYSQLDUMP_BIN:-mysqldump}"

# ── Global state (set during steps, reused across steps) ────
DOMAIN=""
WEB_ROOT=""
EMAIL_PREFIX="contact"
EMAIL_FULL_USER=""

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
    printf '%b\n' "${CYAN}                                                             v2${NC}"
    printf '%b\n' "${GREEN}${BOLD} AUTO-PILOT — NEW WEBSITE LAUNCHER${NC}"
    echo ""
}

section() {
    echo ""
    printf '%b\n' "${BLUE}════════════════════════════════════════════════════════════${NC}"
    printf '%b\n' "${BLUE}  STEP $1 / 5 — $2${NC}"
    printf '%b\n' "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo ""
}

ok()   { printf '%b\n' "${GREEN}  ✅  $*${NC}"; }
warn() { printf '%b\n' "${YELLOW}  ⚠️   $*${NC}"; }
fail() { printf '%b\n' "${RED}  ❌  $*${NC}"; }
info() { printf '%b\n' "${CYAN}  ℹ️   $*${NC}"; }

confirm() {
    local msg="${1:-Proceed?}"
    local ans
    read -r -p "$(printf '%b' "  ${YELLOW}${msg} [y/N]: ${NC}")" ans
    [[ "$ans" == "y" || "$ans" == "Y" ]]
}

# ── MySQL helpers ────────────────────────────────────────────

sql_escape_literal() {
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\'/\'\'}"
    printf '%s' "$v"
}

quote_identifier() {
    local v="$1"
    v="${v//\`/\`\`}"
    printf '`%s`' "$v"
}

mysql_exec()    { "$MYSQL_BIN" -u "$DB_USER" "$@"; }
mysql_exec_db() { local db="$1"; shift; "$MYSQL_BIN" -u "$DB_USER" -D "$db" "$@"; }

database_exists() {
    local db_esc result
    db_esc="$(sql_escape_literal "$1")"
    result="$(mysql_exec -N -s -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${db_esc}' LIMIT 1;" 2>/dev/null || true)"
    [[ "$result" == "$1" ]]
}

# ============================================================
# STEP 1 — NGINX + CERTBOT
# ============================================================

step_nginx_certbot() {
    section "1" "NGINX + CERTBOT SSL"

    # Ask domain
    while [[ -z "$DOMAIN" ]]; do
        read -r -p "  Enter new domain (e.g., example.com): " DOMAIN
        DOMAIN="${DOMAIN#www.}"   # strip www if typed
        DOMAIN="${DOMAIN%/}"       # strip trailing slash
    done

    echo ""
    info "Domain: ${BOLD}$DOMAIN${NC}"

    # Ask web root
    read -r -p "  Web root [/var/www/MISSIRIA/$DOMAIN]: " WEB_ROOT
    WEB_ROOT="${WEB_ROOT:-/var/www/MISSIRIA/$DOMAIN}"

    local avail="/etc/nginx/sites-available/$DOMAIN"
    local enabled="/etc/nginx/sites-enabled/$DOMAIN"

    # Decide: new config or copy from existing?
    echo ""
    if [ -f "$avail" ]; then
        warn "Config for $DOMAIN already exists at $avail"
        echo -e "  ${BLUE}1)${NC} Keep existing config"
        echo -e "  ${BLUE}2)${NC} Replace with a brand-new config"
        echo -e "  ${BLUE}3)${NC} Copy & adapt from another domain"
        read -r -p "  Choice [1-3, default 1]: " nx_choice
        nx_choice="${nx_choice:-1}"
    else
        echo -e "  ${BLUE}1)${NC} Create a brand-new Nginx config"
        echo -e "  ${BLUE}2)${NC} Copy & adapt from another domain"
        read -r -p "  Choice [1-2, default 1]: " nx_choice
        nx_choice="${nx_choice:-1}"
        [[ "$nx_choice" == "2" ]] && nx_choice="3"   # remap for unified logic
    fi

    case "$nx_choice" in
        1) : ;;                        # keep/use as-is
        2) _nginx_create_new ;;
        3) _nginx_copy_from_domain ;;
        *) _nginx_create_new ;;
    esac

    # Enable in sites-enabled
    if [ -f "$avail" ]; then
        [ -L "$enabled" ] || [ -f "$enabled" ] && rm -f "$enabled"
        ln -s "$avail" "$enabled"

        info "Testing Nginx configuration..."
        if nginx -t 2>&1; then
            systemctl reload nginx
            ok "Nginx reloaded — $DOMAIN live on HTTP."
        else
            fail "Nginx config test FAILED. Reverting symlink."
            rm -f "$enabled"
            exit 1
        fi
    fi

    # Certbot SSL
    echo ""
    info "Running Certbot for SSL on $DOMAIN + www.$DOMAIN ..."
    if command -v certbot &>/dev/null; then
        certbot --nginx -d "$DOMAIN" -d "www.$DOMAIN" --redirect
        if [ $? -eq 0 ]; then
            ok "SSL certificate issued and Nginx updated with HTTPS redirect!"
        else
            warn "Certbot had issues — verify: certbot --nginx -d $DOMAIN -d www.$DOMAIN"
        fi
    else
        warn "certbot not found. Install: apt install certbot python3-certbot-nginx"
        warn "Then run manually: certbot --nginx -d $DOMAIN -d www.$DOMAIN"
    fi
}

_nginx_create_new() {
    info "Creating web root: $WEB_ROOT"
    mkdir -p "$WEB_ROOT"
    chown -R www-data:www-data "$WEB_ROOT"
    chmod -R 755 "$WEB_ROOT"

    local avail="/etc/nginx/sites-available/$DOMAIN"
    info "Writing Nginx config → $avail"
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
    ok "Nginx config created."
}

_nginx_copy_from_domain() {
    local avail="/etc/nginx/sites-available/$DOMAIN"

    # List existing configs
    local -a configs=()
    while IFS= read -r f; do
        local bname
        bname="$(basename "$f")"
        [[ "$bname" != "default" && "$bname" != "$DOMAIN" ]] && configs+=("$bname")
    done < <(find /etc/nginx/sites-available/ -maxdepth 1 \( -type f -o -type l \) 2>/dev/null | sort)

    if ((${#configs[@]} == 0)); then
        warn "No other configs to copy from — creating new config."
        _nginx_create_new
        return
    fi

    echo ""
    info "Existing configs:"
    local i
    for i in "${!configs[@]}"; do
        printf '    [%d] %s\n' "$((i+1))" "${configs[$i]}"
    done

    local choice idx src_domain
    read -r -p "  Select number to copy from: " choice
    idx=$((choice - 1))
    if ((idx < 0 || idx >= ${#configs[@]})); then
        warn "Invalid selection — creating new config instead."
        _nginx_create_new
        return
    fi
    src_domain="${configs[$idx]}"

    info "Copying config from $src_domain → $DOMAIN ..."
    sed \
        -e "s|server_name [^;]*;|server_name $DOMAIN www.$DOMAIN;|g" \
        -e "s|root [^;]*;|root $WEB_ROOT;|g" \
        "/etc/nginx/sites-available/$src_domain" > "$avail"

    info "Creating web root: $WEB_ROOT"
    mkdir -p "$WEB_ROOT"
    chown -R www-data:www-data "$WEB_ROOT"
    chmod -R 755 "$WEB_ROOT"

    ok "Config copied and adapted from $src_domain."
}

# ============================================================
# STEP 2 — MYSQL DATABASE
# ============================================================

step_database() {
    section "2" "MYSQL DATABASE"

    # Suggest a DB name based on domain
    local suggested_db
    suggested_db="wp_$(echo "$DOMAIN" | tr '.-' '_')"

    local db_name
    read -r -p "  New database name [$suggested_db]: " db_name
    db_name="${db_name:-$suggested_db}"
    db_name="$(echo "$db_name" | tr '.-' '_')"

    echo ""
    echo -e "  ${BLUE}1)${NC} Create NEW empty database"
    echo -e "  ${BLUE}2)${NC} Copy/Clone from an existing database on this server"
    read -r -p "  Choice [1-2, default 1]: " db_type
    db_type="${db_type:-1}"

    local db_quoted
    db_quoted="$(quote_identifier "$db_name")"

    case "$db_type" in
        2) _db_clone "$db_name" "$db_quoted" ;;
        *) _db_create_new "$db_name" "$db_quoted" ;;
    esac
}

_db_create_new() {
    local db_name="$1" db_quoted="$2"

    if database_exists "$db_name"; then
        warn "Database '$db_name' already exists — skipping creation."
        return
    fi

    mysql_exec -e "CREATE DATABASE ${db_quoted} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || {
        fail "Failed to create database '$db_name'."
        return
    }
    ok "Database '$db_name' created (utf8mb4)."

    echo ""
    local dump_file
    read -r -p "  SQL dump to import (blank to skip) [/home/missiria/dump.sql]: " dump_file
    if [[ -z "$dump_file" ]]; then
        [[ -f "/home/missiria/dump.sql" ]] && dump_file="/home/missiria/dump.sql"
    fi
    if [[ -n "$dump_file" && -f "$dump_file" ]]; then
        info "Importing '$dump_file' into '$db_name' ..."
        mysql_exec_db "$db_name" < "$dump_file" && ok "Import complete." || fail "Import failed — check manually."
    else
        info "No dump imported. You can import later via db-manager.sh."
    fi
}

_db_clone() {
    local db_name="$1" db_quoted="$2"

    # List databases
    local -a db_list=()
    while IFS= read -r row; do
        [[ -n "$row" ]] && db_list+=("$row")
    done < <(mysql_exec -N -s -e "SHOW DATABASES;" | grep -vE '^(information_schema|performance_schema|mysql|sys)$')

    if ((${#db_list[@]} == 0)); then
        warn "No source databases available — creating empty DB."
        _db_create_new "$db_name" "$db_quoted"
        return
    fi

    echo ""
    info "Available databases to clone from:"
    local i
    for i in "${!db_list[@]}"; do
        printf '    [%d] %s\n' "$((i+1))" "${db_list[$i]}"
    done

    local choice idx src_db
    read -r -p "  Select number: " choice
    idx=$((choice - 1))
    if ((idx < 0 || idx >= ${#db_list[@]})); then
        warn "Invalid — creating empty DB instead."
        _db_create_new "$db_name" "$db_quoted"
        return
    fi
    src_db="${db_list[$idx]}"

    # Export
    local tmp_dump="/tmp/autopilot_${src_db}_$(date +%s).sql"
    info "Exporting '$src_db' ..."
    "$MYSQLDUMP_BIN" -u "$DB_USER" "$src_db" > "$tmp_dump" || {
        fail "Export of '$src_db' failed."
        return
    }
    ok "Exported to $tmp_dump"

    # Create new DB
    if database_exists "$db_name"; then
        warn "Database '$db_name' already exists — dropping and recreating."
        mysql_exec -e "DROP DATABASE ${db_quoted};"
    fi
    mysql_exec -e "CREATE DATABASE ${db_quoted} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || {
        fail "Failed to create database '$db_name'."
        rm -f "$tmp_dump"
        return
    }

    # Import
    info "Importing into '$db_name' ..."
    if mysql_exec_db "$db_name" < "$tmp_dump"; then
        ok "Clone complete!"
    else
        fail "Import failed — check manually."
        rm -f "$tmp_dump"
        return
    fi
    rm -f "$tmp_dump"

    # WordPress URL migration
    echo ""
    info "WordPress URL migration (siteurl / home / guid / post_content / postmeta)"
    local wp_prefix old_url new_url
    read -r -p "  WordPress table prefix [wp_]: " wp_prefix
    wp_prefix="${wp_prefix:-wp_}"
    read -r -p "  FROM URL (old site, e.g., https://oldsite.com): " old_url
    read -r -p "  TO URL   (new site) [https://$DOMAIN]: " new_url
    new_url="${new_url:-https://$DOMAIN}"

    if [[ -n "$old_url" && -n "$new_url" ]]; then
        _db_migrate_urls "$db_name" "$wp_prefix" "$old_url" "$new_url"
    else
        warn "URL migration skipped."
    fi
}

_db_migrate_urls() {
    local db_name="$1" prefix="$2" old_url="$3" new_url="$4"

    local old_esc new_esc
    old_esc="$(sql_escape_literal "$old_url")"
    new_esc="$(sql_escape_literal "$new_url")"

    local opts posts postmeta
    opts="$(quote_identifier "${prefix}options")"
    posts="$(quote_identifier "${prefix}posts")"
    postmeta="$(quote_identifier "${prefix}postmeta")"

    info "Migrating: $old_url → $new_url"

    local rows
    rows="$(mysql_exec_db "$db_name" -N -s -e "
        UPDATE ${opts}
        SET option_value = REPLACE(option_value, '${old_esc}', '${new_esc}')
        WHERE option_name IN ('home','siteurl') AND INSTR(option_value,'${old_esc}') > 0;
        SELECT ROW_COUNT();
    " | tail -n1)"
    info "  options (home/siteurl) : ${rows:-0} row(s)"

    rows="$(mysql_exec_db "$db_name" -N -s -e "
        UPDATE ${posts}
        SET guid = REPLACE(guid,'${old_esc}','${new_esc}')
        WHERE INSTR(guid,'${old_esc}') > 0;
        SELECT ROW_COUNT();
    " | tail -n1)"
    info "  posts.guid             : ${rows:-0} row(s)"

    rows="$(mysql_exec_db "$db_name" -N -s -e "
        UPDATE ${posts}
        SET post_content = REPLACE(post_content,'${old_esc}','${new_esc}')
        WHERE INSTR(post_content,'${old_esc}') > 0;
        SELECT ROW_COUNT();
    " | tail -n1)"
    info "  posts.post_content     : ${rows:-0} row(s)"

    rows="$(mysql_exec_db "$db_name" -N -s -e "
        UPDATE ${postmeta}
        SET meta_value = REPLACE(meta_value,'${old_esc}','${new_esc}')
        WHERE meta_value NOT LIKE 'a:%' AND meta_value NOT LIKE 'O:%'
          AND INSTR(meta_value,'${old_esc}') > 0;
        SELECT ROW_COUNT();
    " | tail -n1)"
    info "  postmeta.meta_value    : ${rows:-0} row(s)"

    ok "URL migration complete."
}

# ============================================================
# STEP 3 — EMAIL (Postfix + Maildir)
# ============================================================

step_email() {
    section "3" "EMAIL SETUP (Postfix + Maildir)"

    info "Domain: $DOMAIN"
    echo ""

    # Ask prefix
    read -r -p "  Email prefix [contact]: " EMAIL_PREFIX
    EMAIL_PREFIX="${EMAIL_PREFIX:-contact}"

    local email_addr="${EMAIL_PREFIX}@${DOMAIN}"

    # MISSIRIA naming logic (mirrors email-manager.sh)
    local site_name site_clean
    site_name="$(echo "$DOMAIN" | cut -d'.' -f1)"
    site_clean="$(echo "$site_name" | tr '-' '_')"
    EMAIL_FULL_USER="${EMAIL_PREFIX}_${site_clean}"

    echo ""
    info "Email address : $email_addr"
    info "System user   : $EMAIL_FULL_USER"
    echo ""

    if ! confirm "Create this email account?"; then
        warn "Email setup skipped."
        return
    fi

    # 1) System user
    if id "$EMAIL_FULL_USER" &>/dev/null; then
        warn "System user '$EMAIL_FULL_USER' already exists."
    else
        info "Creating system user '$EMAIL_FULL_USER' ..."
        adduser --disabled-password --gecos "" "$EMAIL_FULL_USER" && ok "User created." || {
            fail "Failed to create user '$EMAIL_FULL_USER'."
            return
        }
    fi

    # 2) Maildir structure
    local home_dir="/home/$EMAIL_FULL_USER"
    local maildir="$home_dir/Maildir"
    if [ ! -d "$maildir" ]; then
        info "Creating Maildir at $maildir ..."
        mkdir -p "$maildir"/{cur,new,tmp}
        ok "Maildir created."
    else
        warn "Maildir already exists."
    fi
    chown -R "$EMAIL_FULL_USER:$EMAIL_FULL_USER" "$home_dir"
    ok "Ownership set: $EMAIL_FULL_USER:$EMAIL_FULL_USER"

    # 3) Postfix virtual alias
    if grep -q "^${email_addr} " /etc/postfix/virtual 2>/dev/null; then
        warn "Postfix alias already exists for $email_addr"
    else
        info "Adding Postfix alias: $email_addr → $EMAIL_FULL_USER"
        echo "$email_addr $EMAIL_FULL_USER" >> /etc/postfix/virtual
        postmap /etc/postfix/virtual
        ok "Postfix alias added and postmap updated."
    fi

    # 4) Reload Postfix
    systemctl reload postfix && ok "Postfix reloaded." || warn "Postfix reload failed — check: systemctl status postfix"
}

# ============================================================
# STEP 4 — VARNISH
# ============================================================

step_varnish() {
    section "4" "VARNISH CACHE ACTIVATION"

    # Detect Varnish
    if ! command -v varnishd &>/dev/null && ! systemctl list-units --type=service 2>/dev/null | grep -q varnish; then
        warn "Varnish does not appear to be installed on this server."
        info "Install: apt install varnish"
        warn "Skipping Varnish step."
        return
    fi

    if ! confirm "Activate Varnish for $DOMAIN?"; then
        warn "Varnish step skipped."
        return
    fi

    # Enable + start Varnish
    info "Enabling and starting Varnish service ..."
    systemctl enable varnish 2>/dev/null || true
    systemctl restart varnish 2>/dev/null
    if systemctl is-active --quiet varnish; then
        ok "Varnish is running."
    else
        warn "Varnish may not be running — check: systemctl status varnish"
    fi

    # Inject proxy headers snippet into wp-config.php
    local wp_config="$WEB_ROOT/wp-config.php"
    if [ -f "$wp_config" ]; then
        if grep -q "HTTP_X_FORWARDED_PROTO" "$wp_config"; then
            warn "Varnish proxy snippet already present in wp-config.php — skipped."
        else
            info "Injecting Varnish proxy headers into $wp_config ..."
            local tmp="${wp_config}.autopilot.tmp"
            awk '
                /^<\?php/ && !done {
                    print
                    print ""
                    print "if (isset($_SERVER['"'"'HTTP_X_FORWARDED_PROTO'"'"']) && strpos($_SERVER['"'"'HTTP_X_FORWARDED_PROTO'"'"'], '"'"'https'"'"') !== false) {"
                    print "    $_SERVER['"'"'HTTPS'"'"'] = '"'"'on'"'"';"
                    print "}"
                    print "if (isset($_SERVER['"'"'HTTP_X_FORWARDED_HOST'"'"'])) {"
                    print "    $_SERVER['"'"'HTTP_HOST'"'"'] = $_SERVER['"'"'HTTP_X_FORWARDED_HOST'"'"'];"
                    print "}"
                    print ""
                    done=1
                    next
                }
                1
            ' "$wp_config" > "$tmp" && mv "$tmp" "$wp_config"
            chown www-data:www-data "$wp_config"
            ok "Varnish proxy snippet added to wp-config.php"
        fi
    else
        warn "wp-config.php not found at $wp_config"
        info "Once WordPress is installed, add this block right after <?php:"
        echo ""
        cat <<'SNIPPET'
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && strpos($_SERVER['HTTP_X_FORWARDED_PROTO'], 'https') !== false) {
    $_SERVER['HTTPS'] = 'on';
}
if (isset($_SERVER['HTTP_X_FORWARDED_HOST'])) {
    $_SERVER['HTTP_HOST'] = $_SERVER['HTTP_X_FORWARDED_HOST'];
}
SNIPPET
        echo ""
    fi
}

# ============================================================
# STEP 5 — AUDIT & VERIFICATION
# ============================================================

step_audit() {
    section "5" "FINAL AUDIT & VERIFICATION"

    local all_ok=1
    local email_addr="${EMAIL_PREFIX}@${DOMAIN}"
    local maildir="/home/$EMAIL_FULL_USER/Maildir"

    # ── Nginx ────────────────────────────────────────────────
    echo -e "\n${BOLD}[NGINX]${NC}"
    local avail="/etc/nginx/sites-available/$DOMAIN"
    local enabled="/etc/nginx/sites-enabled/$DOMAIN"

    [ -f "$avail" ]   && ok "Config exists  : $avail"  || { fail "Config MISSING : $avail";  all_ok=0; }
    [ -L "$enabled" ] && ok "Symlink enabled: $enabled" || { fail "Not enabled    : $enabled"; all_ok=0; }

    if nginx -t 2>&1 | grep -q "successful"; then
        ok "Nginx syntax is valid."
    else
        fail "Nginx config test FAILED!"
        all_ok=0
    fi

    # ── SSL ──────────────────────────────────────────────────
    echo -e "\n${BOLD}[SSL / CERTBOT]${NC}"
    if command -v certbot &>/dev/null; then
        if certbot certificates 2>/dev/null | grep -q "$DOMAIN"; then
            ok "SSL certificate found for $DOMAIN"
        else
            warn "No SSL cert found for $DOMAIN"
            info "Run: certbot --nginx -d $DOMAIN -d www.$DOMAIN"
            all_ok=0
        fi
    else
        warn "certbot not installed — SSL check skipped."
    fi

    # ── HTTP response ────────────────────────────────────────
    echo -e "\n${BOLD}[HTTP RESPONSE]${NC}"
    local http_code
    http_code="$(curl -o /dev/null -s -w "%{http_code}" --max-time 10 "https://$DOMAIN" 2>/dev/null || echo "000")"
    if [[ "$http_code" =~ ^(200|301|302)$ ]]; then
        ok "HTTPS responds HTTP $http_code → https://$DOMAIN"
    else
        warn "HTTP $http_code — site may not be fully up (normal if WP not installed yet)."
    fi

    # ── MySQL ────────────────────────────────────────────────
    echo -e "\n${BOLD}[MYSQL DATABASES]${NC}"
    info "Databases on server:"
    mysql_exec -N -s -e "SHOW DATABASES;" 2>/dev/null \
        | grep -vE '^(information_schema|performance_schema|mysql|sys)$' \
        | while read -r db; do printf '    - %s\n' "$db"; done

    # ── Email ────────────────────────────────────────────────
    echo -e "\n${BOLD}[EMAIL]${NC}"
    if id "$EMAIL_FULL_USER" &>/dev/null; then
        ok "System user   : $EMAIL_FULL_USER"
    else
        fail "System user MISSING: $EMAIL_FULL_USER"
        all_ok=0
    fi

    if grep -q "^${email_addr} " /etc/postfix/virtual 2>/dev/null; then
        ok "Postfix alias : $email_addr → $EMAIL_FULL_USER"
    else
        fail "Postfix alias MISSING for $email_addr"
        info "Fix: echo \"$email_addr $EMAIL_FULL_USER\" | sudo tee -a /etc/postfix/virtual && sudo postmap /etc/postfix/virtual"
        all_ok=0
    fi

    if [ -d "$maildir" ]; then
        local owner
        owner="$(stat -c "%U:%G" "$maildir" 2>/dev/null)"
        if [ "$owner" == "$EMAIL_FULL_USER:$EMAIL_FULL_USER" ]; then
            ok "Maildir       : $maildir ($owner)"
        else
            warn "Maildir ownership wrong: $owner (expected $EMAIL_FULL_USER:$EMAIL_FULL_USER)"
            info "Fix: sudo chown -R $EMAIL_FULL_USER:$EMAIL_FULL_USER /home/$EMAIL_FULL_USER"
            all_ok=0
        fi
    else
        fail "Maildir MISSING: $maildir"
        info "Fix: sudo mkdir -p $maildir/{cur,new,tmp} && sudo chown -R $EMAIL_FULL_USER:$EMAIL_FULL_USER /home/$EMAIL_FULL_USER"
        all_ok=0
    fi

    # ── Varnish ──────────────────────────────────────────────
    echo -e "\n${BOLD}[VARNISH]${NC}"
    if systemctl is-active --quiet varnish 2>/dev/null; then
        ok "Varnish is active."
    else
        warn "Varnish is NOT running (skip if not used)."
    fi

    local wp_config="$WEB_ROOT/wp-config.php"
    if [ -f "$wp_config" ]; then
        if grep -q "HTTP_X_FORWARDED_PROTO" "$wp_config"; then
            ok "Proxy snippet present in wp-config.php"
        else
            fail "Proxy snippet MISSING from wp-config.php"
            all_ok=0
        fi
    else
        info "wp-config.php not found yet — normal if WP not installed."
    fi

    # ── Summary ──────────────────────────────────────────────
    echo ""
    printf '%b\n' "${BLUE}════════════════════════════════════════════════════════════${NC}"
    if [[ "$all_ok" == "1" ]]; then
        printf '%b\n' "${GREEN}${BOLD}  ✅  ALL CHECKS PASSED — $DOMAIN is ready!${NC}"
    else
        printf '%b\n' "${YELLOW}${BOLD}  ⚠️   SOME CHECKS NEED ATTENTION — see warnings above.${NC}"
    fi
    printf '%b\n' "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ============================================================
# MAIN
# ============================================================

print_header

printf '%b\n' "${CYAN}This auto-pilot sets up a complete website in 5 steps:${NC}"
printf '%b\n' "  ${BLUE}1)${NC} Nginx config + Certbot SSL"
printf '%b\n' "  ${BLUE}2)${NC} MySQL database (new or cloned)"
printf '%b\n' "  ${BLUE}3)${NC} Email account (Postfix + Maildir)"
printf '%b\n' "  ${BLUE}4)${NC} Varnish cache activation"
printf '%b\n' "  ${BLUE}5)${NC} Full audit & verification"
echo ""

if ! confirm "Launch auto-pilot now?"; then
    echo "  Cancelled."
    exit 0
fi

step_nginx_certbot
step_database
step_email
step_varnish
step_audit

printf '%b\n' "${GREEN}${BOLD}🎉  Auto-pilot complete for: $DOMAIN${NC}"

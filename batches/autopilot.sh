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
WP_OLD_PREFIX=""    # COPY only: detected from source after clone
WP_PREFIX=""        # COPY only: new prefix chosen by user
OLD_URL=""          # COPY only
NEW_URL=""          # COPY only
GIT_REPO_URL=""     # COPY only: new git remote origin URL

EMAIL_PREFIX="contact"
EMAIL_FULL_USER=""
EMAIL_PASSWORD=""

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
    printf '%b\n' "  ${BOLD}│   ${BLUE}[N]${NC}${BOLD}  NEW website     — blank setup from scratch  │${NC}"
    printf '%b\n' "  ${BOLD}│   ${BLUE}[C]${NC}${BOLD}  COPY website    — duplicate / migrate site  │${NC}"
    printf '%b\n' "  ${BOLD}│   ${RED}[D]${NC}${BOLD}  DELETE site     — purge everything (backup) │${NC}"
    printf '%b\n' "  ${BOLD}│   ${GREEN}[R]${NC}${BOLD}  RESTORE site    — rebuild from backup       │${NC}"
    printf '%b\n' "  ${BOLD}│                                                     │${NC}"
    printf '%b\n' "  ${BOLD}└─────────────────────────────────────────────────────┘${NC}"
    echo ""

    while true; do
        ask "Choice [N/C/D/R]:"
        read -r choice
        case "${choice,,}" in
            n|new)     MODE="new";     break ;;
            c|copy)    MODE="copy";    break ;;
            d|delete)  MODE="delete";  break ;;
            r|restore) MODE="restore"; break ;;
            *) warn "Type N (New), C (Copy), D (Delete), or R (Restore)." ;;
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

    # New git repository URL
    local old_git_url=""
    if [[ -d "$SRC_WEB_ROOT/.git" ]]; then
        old_git_url="$(git -C "$SRC_WEB_ROOT" remote get-url origin 2>/dev/null || true)"
    fi
    echo ""
    printf '%b\n' "  ${CYAN}── GIT REPOSITORY ────────────────────────────────────${NC}"
    if [[ -n "$old_git_url" ]]; then
        info "Current remote URL: $old_git_url"
    else
        info "No git repository detected in source (or no 'origin' remote)."
    fi
    ask "New repository URL for copied project (blank = skip):"
    read -r GIT_REPO_URL
    [[ -n "$GIT_REPO_URL" ]] && info "New remote URL: $GIT_REPO_URL" || info "Git remote: will not be changed."

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
        # Auto-detect siteurl from the source WordPress database
        local src_siteurl=""
        if [[ -n "$SRC_DB" ]]; then
            local opts_table
            opts_table="$(mysql_admin -N -s -D "$SRC_DB" -e "SHOW TABLES LIKE '%\_options';" 2>/dev/null | head -1)"
            if [[ -n "$opts_table" ]]; then
                src_siteurl="$(mysql_admin -N -s -D "$SRC_DB" -e "SELECT option_value FROM \`${opts_table}\` WHERE option_name='siteurl' LIMIT 1;" 2>/dev/null | head -1)"
            fi
        fi
        local default_old_url="${src_siteurl:-https://$SRC_DOMAIN}"
        [[ -n "$src_siteurl" ]] && info "Auto-detected source URL: $src_siteurl"

        ask "FROM URL — source site [$default_old_url]:"
        read -r OLD_URL
        OLD_URL="${OLD_URL:-$default_old_url}"

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

    local pass1 pass2
    while true; do
        printf '%b' "  ${YELLOW}▶ Password for ${EMAIL_PREFIX}@${DOMAIN}: ${NC}"
        read -r -s pass1; printf '\n'
        [[ -z "$pass1" ]] && { warn "Password cannot be empty."; continue; }
        printf '%b' "  ${YELLOW}▶ Confirm password: ${NC}"
        read -r -s pass2; printf '\n'
        [[ "$pass1" != "$pass2" ]] && { warn "Passwords do not match — try again."; continue; }
        EMAIL_PASSWORD="$pass1"
        ok "Email password set."
        break
    done
}

intake_options() {
    echo ""
    printf '%b\n' "  ${CYAN}── OPTIONS ───────────────────────────────────────────${NC}"

    # Detect available PHP-FPM versions for display
    local _avail_php=()
    for _s in /var/run/php/php*-fpm.sock; do
        [[ -S "$_s" ]] && _avail_php+=("$(basename "$_s" | sed 's/php\(.*\)-fpm.sock/\1/')")
    done
    local _php_hint=""
    (( ${#_avail_php[@]} > 0 )) && _php_hint=" (available: ${_avail_php[*]})"
    ask "PHP version [8.3]${_php_hint}:"
    read -r PHP_VER
    PHP_VER="${PHP_VER:-8.3}"
    info "PHP version: $PHP_VER"

    ask "Enable Varnish cache? [y/N]:"
    read -r ENABLE_VARNISH
    ENABLE_VARNISH="${ENABLE_VARNISH:-n}"

    ask "Skip Certbot SSL? (useful for local/dev) [y/N]:"
    read -r SKIP_CERTBOT
    SKIP_CERTBOT="${SKIP_CERTBOT:-n}"
}

intake_mysql_admin() {
    echo ""
    printf '%b\n' "  ${CYAN}── MYSQL ADMIN ───────────────────────────────────────${NC}"

    # Try socket auth first (works when running as root with auth_socket plugin)
    if "$MYSQL_BIN" -u "$MYSQL_ADMIN_USER" -e "SELECT 1;" &>/dev/null; then
        MYSQL_ADMIN_PASS=""
        printf '%b\n' "  ${GREEN}✅  MySQL admin connected via socket (no password needed).${NC}"
        return
    fi

    if [[ -n "$MYSQL_ADMIN_PASS" ]]; then
        if MYSQL_PWD="$MYSQL_ADMIN_PASS" "$MYSQL_BIN" -u "$MYSQL_ADMIN_USER" -e "SELECT 1;" &>/dev/null; then
            printf '%b\n' "  ${GREEN}✅  MySQL admin password already set via env (MYSQL_ADMIN_PASS).${NC}"
            return
        fi
        printf '%b\n' "  ${RED}❌  MYSQL_ADMIN_PASS env var set but connection failed — clearing it.${NC}"
        MYSQL_ADMIN_PASS=""
    fi

    local attempts=0
    while true; do
        (( attempts++ ))
        printf '%b' "  ${YELLOW}▶ Password for MySQL admin user '${MYSQL_ADMIN_USER}' (blank = socket/no-password): ${NC}"
        read -r -s MYSQL_ADMIN_PASS
        printf '\n'

        if MYSQL_PWD="$MYSQL_ADMIN_PASS" "$MYSQL_BIN" -u "$MYSQL_ADMIN_USER" -e "SELECT 1;" &>/dev/null; then
            printf '%b\n' "  ${GREEN}✅  MySQL admin connection OK.${NC}"
            break
        fi

        printf '%b\n' "  ${RED}❌  Cannot connect as '${MYSQL_ADMIN_USER}' — wrong password or user.${NC}"
        MYSQL_ADMIN_PASS=""

        if (( attempts >= 3 )); then
            printf '%b\n' "  ${RED}❌  Too many failed attempts. Aborting.${NC}"
            exit 1
        fi
    done
}

check_mysql_health() {
    printf '%b\n' "  ${CYAN}── DB HEALTH CHECK ──────────────────────────────────${NC}"
    if "$MYSQL_BIN" -u "$MYSQL_ADMIN_USER" -e "SELECT 1;" &>/dev/null; then
        local db_count
        db_count=$("$MYSQL_BIN" -u "$MYSQL_ADMIN_USER" -N -s -e \
            "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema','performance_schema','mysql','sys');" 2>/dev/null)
        printf '%b\n' "  ${GREEN}✅  MySQL is up — ${db_count} site database(s) found.${NC}"
    else
        printf '%b\n' "  ${RED}❌  MySQL is NOT reachable. Cannot continue.${NC}"
        printf '%b\n' "  ${YELLOW}    Run: systemctl start mysql${NC}"
        exit 1
    fi
}

intake_edit_loop() {
    local edit_choice
    while true; do
        echo ""
        printf '%b\n' "  ${CYAN}── EDIT SETTINGS ─────────────────────────────────────${NC}"
        printf '%b\n' "  ${BOLD}[1]${NC}  Domain       : $DOMAIN"
        printf '%b\n' "  ${BOLD}[2]${NC}  Web root     : $WEB_ROOT"
        printf '%b\n' "  ${BOLD}[3]${NC}  Database     : $DB_NAME"
        if [[ "$MODE" == "new" ]]; then
            printf '%b\n' "  ${BOLD}[4]${NC}  DB dump      : ${DB_DUMP:-(none)}"
        fi
        printf '%b\n' "  ${BOLD}[5]${NC}  Email prefix : $EMAIL_PREFIX  →  ${EMAIL_PREFIX}@${DOMAIN}"
        printf '%b\n' "  ${BOLD}[6]${NC}  Varnish      : ${ENABLE_VARNISH}"
        printf '%b\n' "  ${BOLD}[7]${NC}  PHP version  : $PHP_VER"
        printf '%b\n' "  ${BOLD}[8]${NC}  Skip Certbot : $SKIP_CERTBOT"
        if [[ "$MODE" == "copy" ]]; then
            printf '%b\n' "  ${BOLD}[9]${NC}  Source domain: $SRC_DOMAIN"
            printf '%b\n' " ${BOLD}[10]${NC}  Source root  : $SRC_WEB_ROOT"
            printf '%b\n' " ${BOLD}[11]${NC}  Source DB    : $SRC_DB"
            printf '%b\n' " ${BOLD}[12]${NC}  Old URL      : $OLD_URL"
            printf '%b\n' " ${BOLD}[13]${NC}  New URL      : $NEW_URL"
            printf '%b\n' " ${BOLD}[14]${NC}  Git remote   : ${GIT_REPO_URL:-(unchanged)}"
        fi
        printf '%b\n' "  ${BOLD}[0]${NC}  Done — go back to summary"
        echo ""
        ask "Edit which setting? [0 to finish]:"
        read -r edit_choice

        case "$edit_choice" in
            0) break ;;
            1)
                ask "New domain:"
                read -r DOMAIN
                DOMAIN="${DOMAIN#www.}"
                DOMAIN="${DOMAIN%/}"
                local site_clean; site_clean="$(echo "$(echo "$DOMAIN" | cut -d'.' -f1)" | tr '-' '_')"
                EMAIL_FULL_USER="${EMAIL_PREFIX}_${site_clean}"
                ;;
            2) ask "Web root:"; read -r WEB_ROOT ;;
            3)
                ask "Database name:"
                read -r DB_NAME
                DB_NAME="$(echo "$DB_NAME" | tr '.-' '_')"
                ;;
            4)
                [[ "$MODE" == "new" ]] || { warn "Option 4 is only for NEW mode."; continue; }
                ask "SQL dump file (blank = empty DB):"
                read -r DB_DUMP
                ;;
            5)
                ask "Email prefix:"
                read -r EMAIL_PREFIX
                EMAIL_PREFIX="${EMAIL_PREFIX:-contact}"
                local site_n; site_n="$(echo "$DOMAIN" | cut -d'.' -f1)"
                EMAIL_FULL_USER="${EMAIL_PREFIX}_$(echo "$site_n" | tr '-' '_')"
                info "Will create: ${EMAIL_PREFIX}@${DOMAIN}  →  system user: ${EMAIL_FULL_USER}"
                local _ep1 _ep2
                while true; do
                    printf '%b' "  ${YELLOW}▶ New password for ${EMAIL_PREFIX}@${DOMAIN}: ${NC}"
                    read -r -s _ep1; printf '\n'
                    [[ -z "$_ep1" ]] && { warn "Password cannot be empty."; continue; }
                    printf '%b' "  ${YELLOW}▶ Confirm password: ${NC}"
                    read -r -s _ep2; printf '\n'
                    [[ "$_ep1" != "$_ep2" ]] && { warn "Passwords do not match."; continue; }
                    EMAIL_PASSWORD="$_ep1"
                    ok "Email password updated."
                    break
                done
                ;;
            6)
                ask "Enable Varnish? [y/N]:"
                read -r ENABLE_VARNISH
                ENABLE_VARNISH="${ENABLE_VARNISH:-n}"
                ;;
            7) ask "PHP version [8.3]:"; read -r PHP_VER; PHP_VER="${PHP_VER:-8.3}" ;;
            8)
                ask "Skip Certbot? [y/N]:"
                read -r SKIP_CERTBOT
                SKIP_CERTBOT="${SKIP_CERTBOT:-n}"
                ;;
            9)  [[ "$MODE" == "copy" ]] && { ask "Source domain:"; read -r SRC_DOMAIN; } || warn "COPY mode only." ;;
            10) [[ "$MODE" == "copy" ]] && { ask "Source root:"; read -r SRC_WEB_ROOT; } || warn "COPY mode only." ;;
            11) [[ "$MODE" == "copy" ]] && { ask "Source database:"; read -r SRC_DB; } || warn "COPY mode only." ;;
            12) [[ "$MODE" == "copy" ]] && { ask "Old URL:"; read -r OLD_URL; } || warn "COPY mode only." ;;
            13) [[ "$MODE" == "copy" ]] && { ask "New URL:"; read -r NEW_URL; } || warn "COPY mode only." ;;
            14) [[ "$MODE" == "copy" ]] && { ask "Git remote URL (blank = skip):"; read -r GIT_REPO_URL; } || warn "COPY mode only." ;;
            *) warn "Invalid option." ;;
        esac
    done
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
        if [[ -n "$WP_OLD_PREFIX" && -n "$WP_PREFIX" && "$WP_OLD_PREFIX" != "$WP_PREFIX" ]]; then
            printf '    WP prefix     : %s  →  %s\n' "$WP_OLD_PREFIX" "$WP_PREFIX"
        elif [[ -n "$WP_PREFIX" ]]; then
            printf '    WP prefix     : %s\n' "$WP_PREFIX"
        else
            printf '    WP prefix     : %s\n' "(auto-detect after clone)"
        fi
        if [[ -n "$GIT_REPO_URL" ]]; then
            printf '    Git remote    : %s\n' "$GIT_REPO_URL"
        else
            printf '    Git remote    : %s\n' "(unchanged)"
        fi
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

        if [[ -n "$GIT_REPO_URL" && -d "$WEB_ROOT/.git" ]]; then
            info "Updating git remote origin → $GIT_REPO_URL ..."
            git config --global --add safe.directory "$WEB_ROOT" 2>/dev/null || true
            if git -C "$WEB_ROOT" remote set-url origin "$GIT_REPO_URL" 2>&1; then
                ok "Git remote origin updated."
            else
                warn "Could not update git remote — check manually: git -C $WEB_ROOT remote set-url origin <URL>"
            fi
        elif [[ -n "$GIT_REPO_URL" ]]; then
            warn "No .git directory in $WEB_ROOT — cannot set remote URL."
        fi

        # Rewrite robots.txt hostname so the Sitemap: directive (and any other
        # absolute-URL lines like Host:) point at the new domain. Leaving the
        # cloned hostname silently feeds the wrong site to Google (MITP-0669).
        local robots_file="$WEB_ROOT/robots.txt"
        if [[ -f "$robots_file" && -n "$OLD_URL" && -n "$NEW_URL" && "$OLD_URL" != "$NEW_URL" ]]; then
            local old_host="${OLD_URL#http://}"; old_host="${old_host#https://}"; old_host="${old_host%/}"
            local new_host="${NEW_URL#http://}"; new_host="${new_host#https://}"; new_host="${new_host%/}"
            local old_apex="${old_host#www.}"
            local new_apex="${new_host#www.}"
            info "Rewriting robots.txt hostnames: $old_host → $new_host"
            sed -i \
                -e "s#https\?://www\.${old_apex//./\\.}#https://${new_host}#g" \
                -e "s#https\?://${old_apex//./\\.}#https://${new_apex}#g" \
                "$robots_file"
            chown www-data:www-data "$robots_file"
            if grep -qE "^Sitemap: " "$robots_file" 2>/dev/null; then
                ok "robots.txt Sitemap directive now points at: $(grep -E '^Sitemap: ' "$robots_file" | head -1)"
            else
                warn "robots.txt has no Sitemap: directive — consider adding one for Yoast / Rank Math."
            fi
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
                -e "s|/var/log/nginx/${SRC_DOMAIN}|/var/log/nginx/${DOMAIN}|g" \
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
        # If failure is caused by a missing SSL cert (copied from source before certbot ran),
        # fall back to a plain HTTP config so certbot can complete the ACME challenge.
        if nginx -t 2>&1 | grep -q 'cannot load certificate'; then
            warn "SSL cert not found — writing temporary HTTP config so Certbot can run..."
            cp "$avail" "${avail}.ssl-backup"
            _nginx_write_new "$avail"
            if nginx -t 2>&1; then
                systemctl reload nginx
                ok "Temporary HTTP config loaded — Certbot will upgrade to HTTPS."
                info "SSL backup saved at: ${avail}.ssl-backup"
            else
                fail "Nginx config test FAILED even with HTTP config — removing symlink."
                rm -f "$enabled"
            fi
        else
            fail "Nginx config test FAILED — removing symlink. Fix it in sites-available and re-run."
            rm -f "$enabled"
        fi
    fi
}

_nginx_write_new() {
    local avail="$1"
    [[ -f "$avail" ]] && warn "Config already exists — overwriting."

    # Resolve PHP-FPM socket: prefer $PHP_VER, fall back to whatever is running
    local fpm_sock=""
    local _try_ver="$PHP_VER"
    if [[ -S "/var/run/php/php${_try_ver}-fpm.sock" ]]; then
        fpm_sock="/var/run/php/php${_try_ver}-fpm.sock"
    else
        # Find first available socket from installed PHP-FPM versions
        for _sock in /var/run/php/php*-fpm.sock; do
            [[ -S "$_sock" ]] && fpm_sock="$_sock" && break
        done
    fi

    if [[ -z "$fpm_sock" ]]; then
        warn "No PHP-FPM socket found — defaulting to php${_try_ver}-fpm.sock (may need fixing)."
        fpm_sock="/var/run/php/php${_try_ver}-fpm.sock"
    else
        info "PHP-FPM socket: $fpm_sock"
    fi

    info "Writing: $avail"
    cat > "$avail" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;
    root $WEB_ROOT;
    index index.php index.html index.htm;

    access_log /var/log/nginx/${DOMAIN}.access.log;
    error_log  /var/log/nginx/${DOMAIN}.error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${fpm_sock};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF
    ok "Nginx config written (PHP-FPM: ${fpm_sock})."
}

_cleanup_certbot_injections() {
    local own_avail; own_avail="$(readlink -f "/etc/nginx/sites-available/$DOMAIN" 2>/dev/null)"
    for cfg in /etc/nginx/sites-enabled/*; do
        local real_cfg; real_cfg="$(readlink -f "$cfg" 2>/dev/null || echo "$cfg")"
        [[ "$real_cfg" == "$own_avail" ]] && continue
        grep -q "server_name[[:space:]].*\b${DOMAIN}\b" "$real_cfg" 2>/dev/null || continue
        warn "Certbot injected '$DOMAIN' block into $(basename "$real_cfg") — removing..."
        python3 - "$real_cfg" "$DOMAIN" <<'PYEOF'
import sys

filepath, domain = sys.argv[1], sys.argv[2]
with open(filepath) as f:
    content = f.read()

def strip_domain_blocks(text, domain):
    out, i = [], 0
    while i < len(text):
        idx = text.find('server', i)
        if idx == -1:
            out.append(text[i:]); break
        brace = text.find('{', idx)
        if brace == -1:
            out.append(text[i:]); break
        # skip non-server-block 'server' occurrences
        between = text[idx+6:brace]
        if between.strip() and not between.strip() == '':
            non_ws = between.strip()
            if non_ws and non_ws[0] not in ('{', '\n', '\r', ' ', '\t'):
                out.append(text[i:idx+1]); i = idx+1; continue
        out.append(text[i:idx])
        depth, j = 0, brace
        while j < len(text):
            c = text[j]
            if c == '{': depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    block = text[idx:j+1]
                    if domain not in block:
                        out.append(block)
                    i = j + 1; break
            j += 1
        else:
            out.append(text[i:]); break
    return ''.join(out).rstrip() + '\n'

result = strip_domain_blocks(content, domain)
with open(filepath, 'w') as f:
    f.write(result)
PYEOF
        ok "Removed stray certbot block from $(basename "$real_cfg")"
    done
    nginx -t &>/dev/null && systemctl reload nginx || true
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

    local certbot_email="${EMAIL_PREFIX}@${DOMAIN}"
    info "Issuing SSL for $DOMAIN + www.$DOMAIN (contact: $certbot_email) ..."
    if certbot --nginx -d "$DOMAIN" -d "www.$DOMAIN" --redirect \
        --non-interactive --agree-tos -m "$certbot_email"; then
        ok "SSL certificate issued and Nginx updated with HTTPS redirect!"
    else
        warn "Certbot had issues — run manually: certbot --nginx -d $DOMAIN -d www.$DOMAIN"
    fi

    _cleanup_certbot_injections
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
        mysql_admin_db "$DB_NAME" < "$DB_DUMP" && ok "Import complete." || fail "Import failed."
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
    if ! MYSQL_PWD="$MYSQL_ADMIN_PASS" "$MYSQLDUMP_BIN" -u "$MYSQL_ADMIN_USER" "$SRC_DB" > "$tmp_dump"; then
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
    if mysql_admin_db "$DB_NAME" < "$tmp_dump"; then
        ok "Clone complete!"
    else
        fail "Import failed."
        rm -f "$tmp_dump"
        return
    fi
    rm -f "$tmp_dump"

    if [[ -n "$OLD_URL" && -n "$NEW_URL" ]]; then
        _pick_wp_prefix
        _rename_wp_prefix
        _db_migrate_urls
    else
        warn "URL migration skipped (no URLs provided)."
    fi
}

_pick_wp_prefix() {
    info "Detecting WordPress table prefixes in '$DB_NAME' ..."
    local db_esc; db_esc="$(sql_escape_literal "$DB_NAME")"

    local -a detected=()
    while IFS= read -r tbl; do
        [[ -n "$tbl" ]] && detected+=("${tbl%options}")
    done < <(mysql_exec_db "$DB_NAME" -N -s -e \
        "SELECT TABLE_NAME FROM information_schema.TABLES
         WHERE TABLE_SCHEMA='${db_esc}' AND TABLE_NAME LIKE '%options'
         ORDER BY TABLE_NAME;" 2>/dev/null)

    # ── Step 1: identify the OLD (source) prefix ─────────────
    if (( ${#detected[@]} == 0 )); then
        warn "No '*_options' table found — cannot auto-detect source prefix."
        WP_OLD_PREFIX="wp_"
    elif (( ${#detected[@]} == 1 )); then
        WP_OLD_PREFIX="${detected[0]}"
        info "Source prefix detected: ${WP_OLD_PREFIX}"
    else
        echo ""
        printf '%b\n' "  ${CYAN}Multiple prefixes found in source DB '$DB_NAME':${NC}"
        for i in "${!detected[@]}"; do
            printf '%b\n' "    ${BLUE}[$((i+1))]${NC} ${detected[$i]}"
        done
        echo ""
        ask "Select source prefix number (or press Enter to type manually):"
        read -r _pick
        if [[ "$_pick" =~ ^[0-9]+$ ]]; then
            local idx=$(( _pick - 1 ))
            if (( idx >= 0 && idx < ${#detected[@]} )); then
                WP_OLD_PREFIX="${detected[$idx]}"
            fi
        fi
        if [[ -z "$WP_OLD_PREFIX" ]]; then
            ask "Source prefix (e.g., wp_):"
            read -r WP_OLD_PREFIX
            WP_OLD_PREFIX="${WP_OLD_PREFIX:-wp_}"
        fi
        info "Source prefix: $WP_OLD_PREFIX"
    fi

    # ── Step 2: ask for a NEW prefix for the cloned site ─────
    echo ""
    printf '%b\n' "  ${YELLOW}The source tables use prefix: ${BOLD}${WP_OLD_PREFIX}${NC}"
    ask "New prefix for '$DB_NAME' (leave blank to keep '${WP_OLD_PREFIX}'):"
    read -r _new_prefix
    WP_PREFIX="${_new_prefix:-$WP_OLD_PREFIX}"
    ok "New WP prefix: $WP_PREFIX"
}

_rename_wp_prefix() {
    [[ "$WP_OLD_PREFIX" == "$WP_PREFIX" ]] && return

    info "Renaming tables: '${WP_OLD_PREFIX}*' → '${WP_PREFIX}*' in '$DB_NAME' ..."
    local db_esc; db_esc="$(sql_escape_literal "$DB_NAME")"
    local old_esc; old_esc="$(sql_escape_literal "${WP_OLD_PREFIX}%")"

    local -a tables=()
    while IFS= read -r tbl; do
        [[ -n "$tbl" ]] && tables+=("$tbl")
    done < <(mysql_exec_db "$DB_NAME" -N -s -e \
        "SELECT TABLE_NAME FROM information_schema.TABLES
         WHERE TABLE_SCHEMA='${db_esc}' AND TABLE_NAME LIKE '${old_esc}'
         ORDER BY TABLE_NAME;" 2>/dev/null)

    if (( ${#tables[@]} == 0 )); then
        warn "No tables found with prefix '${WP_OLD_PREFIX}' — nothing renamed."
        return
    fi

    local failed=0
    for tbl in "${tables[@]}"; do
        local new_tbl="${WP_PREFIX}${tbl#$WP_OLD_PREFIX}"
        if mysql_exec_db "$DB_NAME" -e "RENAME TABLE \`${tbl}\` TO \`${new_tbl}\`;" 2>/dev/null; then
            info "  Renamed: $tbl → $new_tbl"
        else
            warn "  Failed : $tbl"
            (( failed++ ))
        fi
    done

    # Update prefix-namespaced option_name keys (e.g. wp_user_roles)
    local opts_quoted; opts_quoted="$(quote_identifier "${WP_PREFIX}options")"
    local old_sql; old_sql="$(sql_escape_literal "$WP_OLD_PREFIX")"
    local new_sql; new_sql="$(sql_escape_literal "$WP_PREFIX")"
    mysql_exec_db "$DB_NAME" -e "
        UPDATE ${opts_quoted}
        SET option_name = CONCAT('${new_sql}', SUBSTR(option_name, LENGTH('${old_sql}') + 1))
        WHERE option_name LIKE '${old_sql}%';
    " 2>/dev/null && info "  options prefix keys updated." || warn "  options prefix update skipped."

    # Update usermeta meta_key prefix references
    local usermeta_quoted; usermeta_quoted="$(quote_identifier "${WP_PREFIX}usermeta")"
    mysql_exec_db "$DB_NAME" -e "
        UPDATE ${usermeta_quoted}
        SET meta_key = CONCAT('${new_sql}', SUBSTR(meta_key, LENGTH('${old_sql}') + 1))
        WHERE meta_key LIKE '${old_sql}%';
    " 2>/dev/null && info "  usermeta meta_key prefix updated." || warn "  usermeta prefix update skipped."

    (( failed == 0 )) && ok "All tables renamed: '${WP_OLD_PREFIX}' → '${WP_PREFIX}'" \
                       || warn "${failed} table(s) failed to rename — check manually."

    # Update wp-config.php table_prefix
    local wp_config="$WEB_ROOT/wp-config.php"
    if [[ -f "$wp_config" ]]; then
        sed -i "s/\(\\\$table_prefix[[:space:]]*=[[:space:]]*'\)[^']*'/\1${WP_PREFIX}'/" "$wp_config"
        ok "wp-config.php \$table_prefix updated to '${WP_PREFIX}'."
    fi
}

_db_migrate_urls() {
    local opts actual_siteurl helper php_bin
    opts="$(quote_identifier "${WP_PREFIX}options")"

    # Show the actual siteurl stored in the DB before touching anything.
    actual_siteurl="$(mysql_exec_db "$DB_NAME" -N -s -e \
        "SELECT option_value FROM ${opts} WHERE option_name='siteurl' LIMIT 1;" 2>/dev/null)"
    info "URL migration: $OLD_URL  →  $NEW_URL"
    if [[ -n "$actual_siteurl" && "$actual_siteurl" != "$OLD_URL" ]]; then
        warn "⚠  Mismatch — actual siteurl in DB is: $actual_siteurl"
        warn "   Replacing against that URL instead of the one you entered."
        OLD_URL="$actual_siteurl"
        info "URL migration (corrected): $OLD_URL  →  $NEW_URL"
    fi

    helper="$(dirname "${BASH_SOURCE[0]}")/wp-url-migrate.php"
    [[ -f "$helper" ]] || helper="/home/missiria/linux-terminal-tools/batches/wp-url-migrate.php"
    if [[ ! -f "$helper" ]]; then
        warn "wp-url-migrate.php helper not found — falling back to legacy REPLACE."
        _db_migrate_urls_legacy
        return
    fi

    php_bin="$(command -v php || true)"
    if [[ -z "$php_bin" ]]; then
        warn "php CLI not found — falling back to legacy REPLACE."
        _db_migrate_urls_legacy
        return
    fi

    # Build URL variants so all 4 schemes get migrated in one autopilot pass.
    local -a variants=()
    _push_variant() { local v="$1"; [[ -n "$v" ]] && variants+=("$v"); }
    local old_host="${OLD_URL#http://}"; old_host="${old_host#https://}"; old_host="${old_host%/}"
    _push_variant "https://${old_host}"
    _push_variant "http://${old_host}"
    if [[ "$old_host" == www.* ]]; then
        _push_variant "https://${old_host#www.}"
        _push_variant "http://${old_host#www.}"
    else
        _push_variant "https://www.${old_host}"
        _push_variant "http://www.${old_host}"
    fi

    local mysql_user mysql_pass
    mysql_user="${MYSQL_ADMIN_USER:-root}"
    mysql_pass="${MYSQL_ADMIN_PASSWORD:-}"

    local v rc=0
    for v in "${variants[@]}"; do
        [[ "$v" == "$NEW_URL" ]] && continue
        "$php_bin" "$helper" \
            --db="$DB_NAME" --prefix="$WP_PREFIX" \
            --old="$v" --new="$NEW_URL" \
            --user="$mysql_user" --pass="$mysql_pass" \
            --host="${MYSQL_HOST:-localhost}" \
            2>&1 | sed 's/^/    /'
        rc=$((rc + $?))
    done

    if (( rc != 0 )); then
        warn "URL migration helper reported errors — verify DB state manually."
    fi
    ok "URL migration complete."
}

# Legacy fallback — naive REPLACE, breaks serialized data. Kept only for
# disaster recovery when the PHP helper or CLI is unavailable.
_db_migrate_urls_legacy() {
    local old_esc new_esc opts posts postmeta rows
    old_esc="$(sql_escape_literal "$OLD_URL")"
    new_esc="$(sql_escape_literal "$NEW_URL")"
    opts="$(quote_identifier "${WP_PREFIX}options")"
    posts="$(quote_identifier "${WP_PREFIX}posts")"
    postmeta="$(quote_identifier "${WP_PREFIX}postmeta")"

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

    echo "$EMAIL_FULL_USER:$EMAIL_PASSWORD" | chpasswd
    ok "Password set for $EMAIL_FULL_USER."

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

    # ── SMTP constants in wp-config.php ──────────────────────────────
    local wp_config="$WEB_ROOT/wp-config.php"
    if [[ -f "$wp_config" ]]; then
        local smtp_block
        smtp_block="define('MISSIRIA_SMTP_USERNAME', '${email_addr}');
define('MISSIRIA_SMTP_PASSWORD', '${EMAIL_PASSWORD}');
define('MISSIRIA_SMTP_FROM_EMAIL', '${email_addr}');
define('MISSIRIA_SMTP_FROM_NAME', '$(echo "$DOMAIN" | cut -d'.' -f1 | tr '[:lower:]' '[:upper:]')');
"
        if grep -q "MISSIRIA_SMTP_USERNAME" "$wp_config"; then
            # Update existing block
            sed -i \
                -e "s|define('MISSIRIA_SMTP_USERNAME',[^)]*);|define('MISSIRIA_SMTP_USERNAME', '${email_addr}');|" \
                -e "s|define('MISSIRIA_SMTP_PASSWORD',[^)]*);|define('MISSIRIA_SMTP_PASSWORD', '${EMAIL_PASSWORD}');|" \
                -e "s|define('MISSIRIA_SMTP_FROM_EMAIL',[^)]*);|define('MISSIRIA_SMTP_FROM_EMAIL', '${email_addr}');|" \
                -e "s|define('MISSIRIA_SMTP_FROM_NAME',[^)]*);|define('MISSIRIA_SMTP_FROM_NAME', '$(echo "$DOMAIN" | cut -d'.' -f1 | tr '[:lower:]' '[:upper:]')');|" \
                "$wp_config"
            ok "wp-config.php SMTP constants updated."
        else
            # Inject after opening <?php tag
            local tmp="${wp_config}.smtp.tmp"
            awk -v block="$smtp_block" '
                /^<\?php/ && !done { print; print ""; printf "%s", block; done=1; next }
                1
            ' "$wp_config" > "$tmp" && mv "$tmp" "$wp_config"
            chown www-data:www-data "$wp_config"
            ok "wp-config.php SMTP constants injected."
        fi
    else
        info "wp-config.php not found at $WEB_ROOT — SMTP constants skipped."
    fi

    # ── Dovecot virtual user (lets iOS/Outlook login with full email) ──
    if command -v dovecot &>/dev/null || systemctl list-units --type=service 2>/dev/null | grep -q dovecot; then
        local dovecot_users="/etc/dovecot/users"
        local dovecot_auth_conf="/etc/dovecot/conf.d/10-auth.conf"
        local dovecot_passfile_conf="/etc/dovecot/conf.d/auth-passwdfile.conf.ext"

        # Create users file with correct ownership
        if [[ ! -f "$dovecot_users" ]]; then
            touch "$dovecot_users"
            chmod 640 "$dovecot_users"
            chown root:dovecot "$dovecot_users" 2>/dev/null || true
        fi

        # Hash the password
        local hashed_pass
        if command -v doveadm &>/dev/null; then
            hashed_pass="$(doveadm pw -s SHA512-CRYPT -p "$EMAIL_PASSWORD" 2>/dev/null)"
        else
            hashed_pass="{SHA512-CRYPT}$(openssl passwd -6 "$EMAIL_PASSWORD" 2>/dev/null)"
        fi

        local uid gid
        uid="$(id -u "$EMAIL_FULL_USER")"
        gid="$(id -g "$EMAIL_FULL_USER")"

        if grep -q "^${email_addr}:" "$dovecot_users" 2>/dev/null; then
            sed -i "s|^${email_addr}:.*|${email_addr}:${hashed_pass}:${uid}:${gid}::/home/${EMAIL_FULL_USER}::|" "$dovecot_users"
            ok "Dovecot user updated: $email_addr"
        else
            echo "${email_addr}:${hashed_pass}:${uid}:${gid}::/home/${EMAIL_FULL_USER}::" >> "$dovecot_users"
            ok "Dovecot virtual user added: $email_addr → /home/${EMAIL_FULL_USER}"
        fi

        # Create passwd-file auth config if missing
        if [[ ! -f "$dovecot_passfile_conf" ]]; then
            cat > "$dovecot_passfile_conf" <<'DCONF'
passdb {
  driver = passwd-file
  args = scheme=SHA512-CRYPT /etc/dovecot/users
}
userdb {
  driver = passwd-file
  args = /etc/dovecot/users
  default_fields = home=/home/%n mail=maildir:~/Maildir
}
DCONF
            ok "Dovecot auth-passwdfile.conf.ext created."
        fi

        # Enable !include in 10-auth.conf if not already active
        if [[ -f "$dovecot_auth_conf" ]]; then
            if grep -q "^#!include auth-passwdfile.conf.ext" "$dovecot_auth_conf"; then
                sed -i 's|^#!include auth-passwdfile.conf.ext|!include auth-passwdfile.conf.ext|' "$dovecot_auth_conf"
                ok "Dovecot auth-passwdfile enabled in 10-auth.conf."
            elif ! grep -q "^!include auth-passwdfile.conf.ext" "$dovecot_auth_conf"; then
                echo "!include auth-passwdfile.conf.ext" >> "$dovecot_auth_conf"
                ok "Dovecot auth-passwdfile added to 10-auth.conf."
            fi
        fi

        systemctl reload dovecot 2>/dev/null && ok "Dovecot reloaded — login with: $email_addr" \
            || warn "Could not reload Dovecot — run: systemctl reload dovecot"
    else
        info "Dovecot not found — IMAP login will use system username: $EMAIL_FULL_USER"
    fi
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

    local cert_path="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    local key_path="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    local certs_exist=0
    [[ -f "$cert_path" && -f "$key_path" ]] && certs_exist=1

    if [[ "$certs_exist" -eq 1 ]]; then
        info "Writing Varnish architecture (backend :8080, HTTPS :443 → Varnish :6081) ..."
        cat > "$avail" <<EOF
# ── BACKEND (PHP on port 8080) ────────────────────────────
server {
    listen 8080;
    server_name $DOMAIN www.$DOMAIN;
    root $WEB_ROOT;
    index index.php index.html index.htm;

    access_log /var/log/nginx/${DOMAIN}-backend.access.log;
    error_log  /var/log/nginx/${DOMAIN}-backend.error.log;

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

# ── HTTP → HTTPS redirect ─────────────────────────────────
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;
    return 301 https://\$host\$request_uri;

    access_log /var/log/nginx/${DOMAIN}-http.access.log;
    error_log  /var/log/nginx/${DOMAIN}-http.error.log;
}

# ── FRONT DOOR (HTTPS :443 → Varnish :6081) ──────────────
server {
    listen [::]:443 ssl;
    listen 443 ssl;
    server_name $DOMAIN www.$DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem; # managed by Certbot
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem; # managed by Certbot
    include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot

    access_log /var/log/nginx/${DOMAIN}.access.log;
    error_log  /var/log/nginx/${DOMAIN}.error.log;

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
    else
        warn "SSL certs not found — writing HTTP-only Varnish config. Run certbot when DNS is ready."
        cat > "$avail" <<EOF
# ── BACKEND (PHP on port 8080) ────────────────────────────
server {
    listen 8080;
    server_name $DOMAIN www.$DOMAIN;
    root $WEB_ROOT;
    index index.php index.html index.htm;

    access_log /var/log/nginx/${DOMAIN}-backend.access.log;
    error_log  /var/log/nginx/${DOMAIN}-backend.error.log;

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

# ── HTTP → Varnish :6081 (no SSL yet) ────────────────────
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;

    access_log /var/log/nginx/${DOMAIN}.access.log;
    error_log  /var/log/nginx/${DOMAIN}.error.log;

    location / {
        proxy_pass http://127.0.0.1:6081;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
        proxy_set_header X-Forwarded-Port  80;
    }
}
EOF
    fi
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

# ============================================================
# DELETE / RESTORE — site removal & rollback
# ============================================================

# ── Shared state for delete + restore ────────────────────────
DEL_DOMAIN=""
DEL_WEB_ROOT=""
DEL_SLUG=""
DEL_BRANCH=""
DEL_DB_NAME=""
DEL_DB_PREFIX=""
DEL_EMAIL_USER=""
DEL_GIT_REMOTE=""
DEL_BACKUP_DIR=""
DRY_RUN="${DRY_RUN:-n}"                              # export DRY_RUN=y for dry mode
DEL_BACKUP_ROOT="${DEL_BACKUP_ROOT:-/root}"           # override for tests

# Docroots that must never be deleted (sync-plugin master, shared templates).
DEL_BLOCKLIST=(
    "/var/www/MISSIRIA/eksit/eksit_ik"
)

# Run or echo a command depending on DRY_RUN.
run() {
    if [[ "$DRY_RUN" == "y" ]]; then
        printf '%b\n' "  ${YELLOW}[dry-run]${NC} $*"
    else
        eval "$@"
    fi
}

# Read a wp-config.php value: extract_wp_const <file> <NAME>
extract_wp_const() {
    local f="$1" name="$2"
    sed -nE "s/^[[:space:]]*define[[:space:]]*\\([[:space:]]*'${name}'[[:space:]]*,[[:space:]]*'([^']*)'.*/\\1/p" "$f" | head -1
}

# Read $table_prefix.
extract_wp_prefix() {
    local f="$1"
    sed -nE "s/^[[:space:]]*\\\$table_prefix[[:space:]]*=[[:space:]]*'([^']*)'.*/\\1/p" "$f" | head -1
}

# ── intake_delete_target ─────────────────────────────────────
intake_delete_target() {
    echo ""
    printf '%b\n' "  ${CYAN}── DELETE TARGET ─────────────────────────────────────${NC}"
    echo ""

    local -a sites=()
    while IFS= read -r cfg; do
        [[ -f "$cfg" ]] && sites+=("$cfg")
    done < <(find /var/www/MISSIRIA/mit /var/www/MISSIRIA/eksit -maxdepth 2 -name wp-config.php 2>/dev/null | sort)

    if ((${#sites[@]} == 0)); then
        fail "No MIT/EKSIT sites found (no wp-config.php under /var/www/MISSIRIA/{mit,eksit}/*/)."
        exit 1
    fi

    info "Sites detected:"
    local i=1
    local -a idx_docroot=() idx_domain=() idx_db=() idx_prefix=() idx_slug=() idx_branch=()
    for cfg in "${sites[@]}"; do
        local docroot; docroot="$(dirname "$cfg")"
        local branch; branch="$(basename "$(dirname "$docroot")")"
        local slug;   slug="$(basename "$docroot")"
        local db;     db="$(extract_wp_const "$cfg" DB_NAME)"
        local prefix; prefix="$(extract_wp_prefix "$cfg")"
        local home;   home="$(extract_wp_const "$cfg" WP_HOME)"
        [[ -z "$home" ]] && home="$(extract_wp_const "$cfg" WP_SITEURL)"
        local domain; domain="${home#https://}"; domain="${domain#http://}"; domain="${domain#www.}"; domain="${domain%%/*}"
        # Fallback 1: query DB options table (WP_HOME often stored there, not in wp-config).
        if [[ -z "$domain" && -n "$db" && -n "$prefix" ]]; then
            local db_home
            db_home="$(mysql_admin -N -s -e "SELECT option_value FROM \`${db}\`.\`${prefix}options\` WHERE option_name='home' LIMIT 1;" 2>/dev/null)"
            [[ -z "$db_home" ]] && db_home="$(mysql_admin -N -s -e "SELECT option_value FROM \`${db}\`.\`${prefix}options\` WHERE option_name='siteurl' LIMIT 1;" 2>/dev/null)"
            domain="${db_home#https://}"; domain="${domain#http://}"; domain="${domain#www.}"; domain="${domain%%/*}"
        fi
        # Fallback 2: grep nginx sites-available for a vhost whose root points at this docroot.
        if [[ -z "$domain" ]]; then
            local vhost
            vhost="$(grep -rlE "root[[:space:]]+${docroot}[[:space:]]*;" /etc/nginx/sites-available/ 2>/dev/null | head -1)"
            if [[ -n "$vhost" ]]; then
                domain="$(awk '/server_name/ {for(i=2;i<=NF;i++){gsub(";","",$i); if($i!="_"&&$i!=""){print $i; exit}}}' "$vhost")"
                domain="${domain#www.}"
            fi
        fi
        [[ -z "$domain" ]] && domain="<unknown>"
        printf "    ${BLUE}[%d]${NC} %-30s → %-14s db=%-25s slug=%s\n" "$i" "$domain" "$branch" "$db" "$slug"
        idx_docroot+=("$docroot"); idx_domain+=("$domain"); idx_db+=("$db")
        idx_prefix+=("$prefix"); idx_slug+=("$slug"); idx_branch+=("$branch")
        i=$((i+1))
    done
    echo ""

    local choice
    while true; do
        ask "Site number to DELETE (or type domain exactly):"
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            local n=$((choice - 1))
            if ((n >= 0 && n < ${#sites[@]})); then
                DEL_WEB_ROOT="${idx_docroot[$n]}"
                DEL_DOMAIN="${idx_domain[$n]}"
                DEL_DB_NAME="${idx_db[$n]}"
                DEL_DB_PREFIX="${idx_prefix[$n]}"
                DEL_SLUG="${idx_slug[$n]}"
                DEL_BRANCH="${idx_branch[$n]}"
                break
            fi
        else
            for n in "${!idx_domain[@]}"; do
                if [[ "${idx_domain[$n]}" == "$choice" ]]; then
                    DEL_WEB_ROOT="${idx_docroot[$n]}"
                    DEL_DOMAIN="${idx_domain[$n]}"
                    DEL_DB_NAME="${idx_db[$n]}"
                    DEL_DB_PREFIX="${idx_prefix[$n]}"
                    DEL_SLUG="${idx_slug[$n]}"
                    DEL_BRANCH="${idx_branch[$n]}"
                    break 2
                fi
            done
        fi
        warn "Invalid selection."
    done

    # Blocklist check.
    for blocked in "${DEL_BLOCKLIST[@]}"; do
        if [[ "$DEL_WEB_ROOT" == "$blocked" ]]; then
            fail "$DEL_WEB_ROOT is on the delete-blocklist (sync-plugin master / shared template). Aborting."
            exit 1
        fi
    done
    if [[ ! -f "$DEL_WEB_ROOT/wp-config.php" ]]; then
        fail "$DEL_WEB_ROOT/wp-config.php missing — refusing to delete a non-WP directory."
        exit 1
    fi

    # Look up mailbox user from /etc/postfix/virtual.
    DEL_EMAIL_USER="$(awk -v d="$DEL_DOMAIN" '$1 ~ ("@"d"$") {print $2; exit}' /etc/postfix/virtual 2>/dev/null || true)"

    # Capture git remote for the manual-checklist section (repo will be gone by then).
    DEL_GIT_REMOTE=""
    if [[ -d "$DEL_WEB_ROOT/.git" ]]; then
        DEL_GIT_REMOTE="$(git -C "$DEL_WEB_ROOT" remote get-url origin 2>/dev/null || true)"
    fi
}

# ── intake_delete_confirm — 2× typed domain + summary ───────
intake_delete_confirm() {
    echo ""
    printf '%b\n' "  ${RED}${BOLD}══════════════════ DELETE PLAN ══════════════════${NC}"
    printf '%b\n' "  Domain          : ${BOLD}$DEL_DOMAIN${NC}"
    printf '%b\n' "  Web root        : $DEL_WEB_ROOT"
    printf '%b\n' "  Branch          : $DEL_BRANCH / slug $DEL_SLUG"
    printf '%b\n' "  Database        : $DEL_DB_NAME  (prefix ${DEL_DB_PREFIX:-<unknown>})"
    printf '%b\n' "  Mailbox user    : ${DEL_EMAIL_USER:-<none in /etc/postfix/virtual>}"
    printf '%b\n' "  Nginx vhost     : /etc/nginx/sites-available/$DEL_DOMAIN"
    printf '%b\n' "  TLS cert        : /etc/letsencrypt/live/$DEL_DOMAIN"
    printf '%b\n' "  OpenDKIM        : /etc/opendkim/keys/$DEL_DOMAIN + Key/Signing/Trusted tables"
    printf '%b\n' "  Git remote      : ${DEL_GIT_REMOTE:-<none>} (repo NOT deleted on GitHub — manual)"
    printf '%b\n' "  Dry-run         : ${DRY_RUN}"
    printf '%b\n' "  Backup dir      : ${DEL_BACKUP_ROOT}/.deleted-${DEL_DOMAIN}-<epoch>/"
    printf '%b\n' "  ${RED}${BOLD}═════════════════════════════════════════════════${NC}"
    echo ""

    if [[ "$DRY_RUN" != "y" ]]; then
        if [[ -z "$DEL_DOMAIN" || "$DEL_DOMAIN" == "<unknown>" ]]; then
            fail "Cannot resolve domain for $DEL_WEB_ROOT (no WP_HOME in wp-config, no DB match, no nginx vhost). Aborting for safety."
            exit 1
        fi
        local t1 t2
        ask "Type the domain ${BOLD}${DEL_DOMAIN}${NC} to confirm deletion:"
        read -r t1
        if [[ "$t1" != "$DEL_DOMAIN" ]]; then
            fail "Confirmation mismatch. Aborting."
            exit 1
        fi
        ask "Type it ONE MORE TIME:"
        read -r t2
        if [[ "$t2" != "$DEL_DOMAIN" ]]; then
            fail "Confirmation mismatch. Aborting."
            exit 1
        fi
    else
        warn "DRY RUN mode — no changes will be applied. Backup phase still runs."
    fi
}

# ── exec_delete_backup — everything goes to /root/.deleted-<domain>-<epoch>/ ──
exec_delete_backup() {
    section "1/9" "BACKUP"

    local epoch; epoch="$(date +%s)"
    DEL_BACKUP_DIR="${DEL_BACKUP_ROOT}/.deleted-${DEL_DOMAIN}-${epoch}"
    mkdir -p "$DEL_BACKUP_DIR"

    info "Backup dir: $DEL_BACKUP_DIR"

    # 1. Docroot tarball (exclude caches).
    if [[ -d "$DEL_WEB_ROOT" ]]; then
        info "Tar docroot → docroot.tar.gz"
        tar --exclude="$DEL_WEB_ROOT/wp-content/cache" \
            --exclude="$DEL_WEB_ROOT/wp-content/uploads/cache" \
            -czf "$DEL_BACKUP_DIR/docroot.tar.gz" \
            -C / "${DEL_WEB_ROOT#/}" 2>>"$DEL_BACKUP_DIR/backup.err" \
            || { fail "docroot tar failed — check $DEL_BACKUP_DIR/backup.err"; exit 1; }
    else
        warn "Web root missing on disk — skipping docroot tar."
    fi

    # 2. Database dump.
    if [[ -n "$DEL_DB_NAME" ]] && database_exists "$DEL_DB_NAME"; then
        info "mysqldump $DEL_DB_NAME → db.sql.gz"
        mysql_admin -e "SET GLOBAL innodb_stats_on_metadata = 0;" 2>/dev/null || true
        MYSQL_PWD="$MYSQL_ADMIN_PASS" "$MYSQLDUMP_BIN" \
            -u "$MYSQL_ADMIN_USER" \
            --single-transaction --routines --triggers --add-drop-table \
            "$DEL_DB_NAME" 2>>"$DEL_BACKUP_DIR/backup.err" \
            | gzip > "$DEL_BACKUP_DIR/db.sql.gz" \
            || { fail "mysqldump failed — check $DEL_BACKUP_DIR/backup.err"; exit 1; }
    else
        warn "DB $DEL_DB_NAME not found — skipping dump."
    fi

    # 3. Nginx vhost.
    for f in "/etc/nginx/sites-available/$DEL_DOMAIN" "/etc/nginx/sites-available/$DEL_DOMAIN.conf"; do
        [[ -f "$f" ]] && cp -a "$f" "$DEL_BACKUP_DIR/nginx.conf" && break
    done
    [[ -f "$DEL_BACKUP_DIR/nginx.conf" ]] && info "Nginx vhost saved." || warn "No nginx vhost found."

    # 4. Certbot live + renewal.
    if [[ -d "/etc/letsencrypt/live/$DEL_DOMAIN" ]] || [[ -f "/etc/letsencrypt/renewal/$DEL_DOMAIN.conf" ]]; then
        info "Tar certbot live + renewal → certbot-live.tar.gz"
        tar -czf "$DEL_BACKUP_DIR/certbot-live.tar.gz" \
            -C / \
            "etc/letsencrypt/live/$DEL_DOMAIN" \
            "etc/letsencrypt/renewal/$DEL_DOMAIN.conf" \
            "etc/letsencrypt/archive/$DEL_DOMAIN" \
            2>>"$DEL_BACKUP_DIR/backup.err" || warn "Some cert paths missing — partial tar."
    fi

    # 5. OpenDKIM keys.
    if [[ -d "/etc/opendkim/keys/$DEL_DOMAIN" ]]; then
        info "Tar DKIM keys → dkim.tar.gz"
        tar -czf "$DEL_BACKUP_DIR/dkim.tar.gz" -C / "etc/opendkim/keys/$DEL_DOMAIN" \
            2>>"$DEL_BACKUP_DIR/backup.err" || warn "DKIM tar had errors."
    fi

    # 6. Mailbox.
    if [[ -n "$DEL_EMAIL_USER" && -d "/home/$DEL_EMAIL_USER/Maildir" ]]; then
        info "Tar mailbox /home/$DEL_EMAIL_USER/Maildir → maildir.tar.gz"
        tar -czf "$DEL_BACKUP_DIR/maildir.tar.gz" -C / "home/$DEL_EMAIL_USER" \
            2>>"$DEL_BACKUP_DIR/backup.err" || warn "Maildir tar had errors."
    fi

    # 7. Manifest for restore.
    cat > "$DEL_BACKUP_DIR/manifest.json" <<EOF
{
  "domain":       "$DEL_DOMAIN",
  "web_root":     "$DEL_WEB_ROOT",
  "slug":         "$DEL_SLUG",
  "branch":       "$DEL_BRANCH",
  "db_name":      "$DEL_DB_NAME",
  "db_prefix":    "$DEL_DB_PREFIX",
  "email_user":   "$DEL_EMAIL_USER",
  "git_remote":   "$DEL_GIT_REMOTE",
  "epoch":        "$epoch",
  "autopilot":    "v3-delete"
}
EOF
    ok "Backup complete → $DEL_BACKUP_DIR"
    ls -lh "$DEL_BACKUP_DIR" | tail -n +2 | awk '{printf "    %-8s %s\n", $5, $NF}'
}

# ── exec_delete_nginx ────────────────────────────────────────
exec_delete_nginx() {
    section "2/9" "NGINX"
    for f in "/etc/nginx/sites-enabled/$DEL_DOMAIN" "/etc/nginx/sites-enabled/$DEL_DOMAIN.conf"; do
        [[ -L "$f" || -f "$f" ]] && run "unlink '$f'"
    done
    for f in "/etc/nginx/sites-available/$DEL_DOMAIN" "/etc/nginx/sites-available/$DEL_DOMAIN.conf"; do
        [[ -f "$f" ]] && run "rm -f '$f'"
    done
    if [[ "$DRY_RUN" != "y" ]]; then
        nginx -t 2>/dev/null && systemctl reload nginx && ok "nginx reloaded" || warn "nginx -t failed; not reloading"
    fi
}

# ── exec_delete_certbot ──────────────────────────────────────
exec_delete_certbot() {
    section "3/9" "CERTBOT"
    if [[ -d "/etc/letsencrypt/live/$DEL_DOMAIN" ]]; then
        run "certbot revoke --non-interactive --cert-name '$DEL_DOMAIN' --reason superseded 2>&1 | tail -3 || true"
        run "certbot delete --non-interactive --cert-name '$DEL_DOMAIN' 2>&1 | tail -3 || true"
    else
        info "No cert for $DEL_DOMAIN — skipping revoke."
    fi
}

# ── exec_delete_email ────────────────────────────────────────
exec_delete_email() {
    section "4/9" "EMAIL / DKIM"

    # Postfix virtual: remove any line whose LHS ends with @$DEL_DOMAIN.
    if grep -qE "@${DEL_DOMAIN}[[:space:]]" /etc/postfix/virtual 2>/dev/null; then
        run "sed -i.bak-delete-$$ '/@${DEL_DOMAIN}[[:space:]]/d' /etc/postfix/virtual"
        run "postmap /etc/postfix/virtual"
    fi

    # Postfix main.cf: strip $DEL_DOMAIN from virtual_alias_domains =.
    if grep -qE "^virtual_alias_domains[[:space:]]*=" /etc/postfix/main.cf; then
        run "sed -i.bak-delete-$$ -E 's/(virtual_alias_domains[[:space:]]*=.*)([[:space:]]*,[[:space:]]*|[[:space:]]+)${DEL_DOMAIN//./\\.}\\b/\\1/; s/(virtual_alias_domains[[:space:]]*=[[:space:]]*)${DEL_DOMAIN//./\\.}[[:space:]]*,?[[:space:]]*/\\1/' /etc/postfix/main.cf"
    fi
    [[ "$DRY_RUN" != "y" ]] && systemctl reload postfix 2>/dev/null && ok "postfix reloaded"

    # OpenDKIM tables.
    for tbl in KeyTable SigningTable TrustedHosts; do
        if grep -q "$DEL_DOMAIN" "/etc/opendkim/$tbl" 2>/dev/null; then
            run "sed -i.bak-delete-$$ '/${DEL_DOMAIN//./\\.}/d' '/etc/opendkim/$tbl'"
        fi
    done
    [[ -d "/etc/opendkim/keys/$DEL_DOMAIN" ]] && run "rm -rf '/etc/opendkim/keys/$DEL_DOMAIN'"
    [[ "$DRY_RUN" != "y" ]] && systemctl reload opendkim 2>/dev/null && ok "opendkim reloaded"

    # Dovecot users file.
    if [[ -n "$DEL_EMAIL_USER" ]] && grep -q "^${DEL_EMAIL_USER}:" /etc/dovecot/users 2>/dev/null; then
        run "sed -i.bak-delete-$$ '/^${DEL_EMAIL_USER}:/d' /etc/dovecot/users"
    fi
}

# ── exec_delete_mailbox ─────────────────────────────────────
exec_delete_mailbox() {
    section "5/9" "MAILBOX"
    if [[ -z "$DEL_EMAIL_USER" ]]; then
        info "No mailbox user recorded — skipping."
        return
    fi
    if id "$DEL_EMAIL_USER" &>/dev/null; then
        run "userdel -r '$DEL_EMAIL_USER' 2>/dev/null || rm -rf '/home/$DEL_EMAIL_USER'"
    elif [[ -d "/home/$DEL_EMAIL_USER" ]]; then
        run "rm -rf '/home/$DEL_EMAIL_USER'"
    fi
}

# ── exec_delete_database ────────────────────────────────────
exec_delete_database() {
    section "6/9" "DATABASE"
    if [[ -z "$DEL_DB_NAME" ]]; then
        info "No DB name — skipping."
        return
    fi
    if database_exists "$DEL_DB_NAME"; then
        local qdb; qdb="$(quote_identifier "$DEL_DB_NAME")"
        run "mysql_admin -e \"DROP DATABASE $qdb;\""
    else
        info "DB $DEL_DB_NAME already absent."
    fi
}

# ── exec_delete_files ───────────────────────────────────────
exec_delete_files() {
    section "7/9" "FILES"
    if [[ -d "$DEL_WEB_ROOT" ]]; then
        run "rm -rf '$DEL_WEB_ROOT'"
    else
        info "Web root already gone."
    fi
}

# ── exec_delete_logs ────────────────────────────────────────
exec_delete_logs() {
    section "8/9" "LOGS"
    # Kept out of the backup on purpose — logs are noise, not state.
    for f in /var/log/nginx/${DEL_DOMAIN}*.log*; do
        [[ -f "$f" ]] && run "rm -f '$f'"
    done
}

# ── exec_delete_manual_checklist ────────────────────────────
exec_delete_manual_checklist() {
    section "9/9" "MANUAL CHECKLIST"
    printf '%b\n' "  ${BOLD}${YELLOW}MANUAL STEPS REMAINING for $DEL_DOMAIN${NC}"
    printf '%b\n' "    1) Contabo DNS panel     — remove zone for $DEL_DOMAIN"
    printf '%b\n' "    2) Cloudflare            — remove zone if managed there"
    printf '%b\n' "    3) GitHub repo           — archive/delete: ${DEL_GIT_REMOTE:-<none>}"
    printf '%b\n' "    4) Google Search Console — remove property for $DEL_DOMAIN and www.$DEL_DOMAIN"
    printf '%b\n' "    5) External SEO tools    — Yoast/Semrush/Ahrefs project entries"
    echo ""
    printf '%b\n' "  ${GREEN}${BOLD}Backup preserved at:${NC} $DEL_BACKUP_DIR"
    printf '%b\n' "  ${GREEN}Restore command:${NC}     autopilot.sh   → mode R   → paste backup dir"
}

# ============================================================
# RESTORE — rebuild from a backup dir
# ============================================================

RES_BACKUP_DIR=""
RES_FORCE="${RES_FORCE:-n}"

# ── intake_restore_source ───────────────────────────────────
intake_restore_source() {
    echo ""
    printf '%b\n' "  ${CYAN}── RESTORE SOURCE ────────────────────────────────────${NC}"
    echo ""

    local -a backups=()
    while IFS= read -r d; do
        [[ -f "$d/manifest.json" ]] && backups+=("$d")
    done < <(find "$DEL_BACKUP_ROOT" -maxdepth 1 -type d -name '.deleted-*' 2>/dev/null | sort -r)

    if ((${#backups[@]} > 0)); then
        info "Available backups (newest first):"
        for i in "${!backups[@]}"; do
            local dom epoch
            dom="$(sed -nE 's/.*"domain":[[:space:]]*"([^"]+)".*/\1/p' "${backups[$i]}/manifest.json" | head -1)"
            epoch="$(sed -nE 's/.*"epoch":[[:space:]]*"([^"]+)".*/\1/p' "${backups[$i]}/manifest.json" | head -1)"
            local when; when="$(date -d "@$epoch" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')"
            printf '    ${BLUE}[%d]${NC} %s   %s   ← %s\n' "$((i+1))" "$dom" "$when" "${backups[$i]}"
        done
        echo ""
        ask "Backup number (or paste full path):"
    else
        ask "Backup dir full path (contains manifest.json):"
    fi

    local choice
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((${#backups[@]} > 0)); then
        local n=$((choice - 1))
        ((n >= 0 && n < ${#backups[@]})) && RES_BACKUP_DIR="${backups[$n]}"
    else
        RES_BACKUP_DIR="$choice"
    fi

    if [[ ! -f "$RES_BACKUP_DIR/manifest.json" ]]; then
        fail "No manifest.json at $RES_BACKUP_DIR"
        exit 1
    fi

    DEL_DOMAIN="$(sed -nE 's/.*"domain":[[:space:]]*"([^"]+)".*/\1/p' "$RES_BACKUP_DIR/manifest.json" | head -1)"
    DEL_WEB_ROOT="$(sed -nE 's/.*"web_root":[[:space:]]*"([^"]+)".*/\1/p' "$RES_BACKUP_DIR/manifest.json" | head -1)"
    DEL_SLUG="$(sed -nE 's/.*"slug":[[:space:]]*"([^"]+)".*/\1/p' "$RES_BACKUP_DIR/manifest.json" | head -1)"
    DEL_BRANCH="$(sed -nE 's/.*"branch":[[:space:]]*"([^"]+)".*/\1/p' "$RES_BACKUP_DIR/manifest.json" | head -1)"
    DEL_DB_NAME="$(sed -nE 's/.*"db_name":[[:space:]]*"([^"]+)".*/\1/p' "$RES_BACKUP_DIR/manifest.json" | head -1)"
    DEL_DB_PREFIX="$(sed -nE 's/.*"db_prefix":[[:space:]]*"([^"]+)".*/\1/p' "$RES_BACKUP_DIR/manifest.json" | head -1)"
    DEL_EMAIL_USER="$(sed -nE 's/.*"email_user":[[:space:]]*"([^"]+)".*/\1/p' "$RES_BACKUP_DIR/manifest.json" | head -1)"
    DEL_GIT_REMOTE="$(sed -nE 's/.*"git_remote":[[:space:]]*"([^"]+)".*/\1/p' "$RES_BACKUP_DIR/manifest.json" | head -1)"
}

# ── intake_restore_confirm ──────────────────────────────────
intake_restore_confirm() {
    echo ""
    printf '%b\n' "  ${GREEN}${BOLD}══════════════════ RESTORE PLAN ══════════════════${NC}"
    printf '%b\n' "  Backup dir      : $RES_BACKUP_DIR"
    printf '%b\n' "  Domain          : $DEL_DOMAIN"
    printf '%b\n' "  Web root        : $DEL_WEB_ROOT"
    printf '%b\n' "  Branch / slug   : $DEL_BRANCH / $DEL_SLUG"
    printf '%b\n' "  Database        : $DEL_DB_NAME  (prefix ${DEL_DB_PREFIX:-<unknown>})"
    printf '%b\n' "  Mailbox user    : ${DEL_EMAIL_USER:-<none>}"
    printf '%b\n' "  Force overwrite : ${RES_FORCE}"
    printf '%b\n' "  ${GREEN}${BOLD}══════════════════════════════════════════════════${NC}"
    echo ""

    # Collision guard.
    if [[ "$RES_FORCE" != "y" ]]; then
        local -a collisions=()
        [[ -d "$DEL_WEB_ROOT" ]] && collisions+=("docroot $DEL_WEB_ROOT")
        [[ -f "/etc/nginx/sites-available/$DEL_DOMAIN" ]] && collisions+=("nginx vhost")
        [[ -n "$DEL_DB_NAME" ]] && database_exists "$DEL_DB_NAME" && collisions+=("database $DEL_DB_NAME")
        [[ -n "$DEL_EMAIL_USER" ]] && id "$DEL_EMAIL_USER" &>/dev/null && collisions+=("system user $DEL_EMAIL_USER")
        if ((${#collisions[@]} > 0)); then
            fail "Collisions detected — refusing to restore. Set RES_FORCE=y to overwrite."
            for c in "${collisions[@]}"; do printf '    - %s\n' "$c"; done
            exit 1
        fi
    fi

    confirm "Proceed with RESTORE?" || { info "Cancelled."; exit 0; }
}

# ── exec_restore_files ──────────────────────────────────────
exec_restore_files() {
    section "1/7" "RESTORE FILES"
    [[ -f "$RES_BACKUP_DIR/docroot.tar.gz" ]] || { warn "No docroot.tar.gz — skipping."; return; }
    run "tar -xzf '$RES_BACKUP_DIR/docroot.tar.gz' -C /"
    [[ -d "$DEL_WEB_ROOT" ]] && run "chown -R www-data:www-data '$DEL_WEB_ROOT'"
}

# ── exec_restore_database ───────────────────────────────────
exec_restore_database() {
    section "2/7" "RESTORE DATABASE"
    [[ -f "$RES_BACKUP_DIR/db.sql.gz" ]] || { warn "No db.sql.gz — skipping."; return; }
    local qdb; qdb="$(quote_identifier "$DEL_DB_NAME")"
    run "mysql_admin -e \"CREATE DATABASE IF NOT EXISTS $qdb DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\""
    if [[ "$DRY_RUN" != "y" ]]; then
        gunzip -c "$RES_BACKUP_DIR/db.sql.gz" | MYSQL_PWD="$MYSQL_ADMIN_PASS" "$MYSQL_BIN" -u "$MYSQL_ADMIN_USER" "$DEL_DB_NAME"
    else
        printf '%b\n' "  ${YELLOW}[dry-run]${NC} gunzip -c $RES_BACKUP_DIR/db.sql.gz | mysql $DEL_DB_NAME"
    fi
}

# ── exec_restore_nginx ──────────────────────────────────────
exec_restore_nginx() {
    section "3/7" "RESTORE NGINX"
    [[ -f "$RES_BACKUP_DIR/nginx.conf" ]] || { warn "No nginx.conf — skipping."; return; }
    run "cp '$RES_BACKUP_DIR/nginx.conf' '/etc/nginx/sites-available/$DEL_DOMAIN'"
    [[ -L "/etc/nginx/sites-enabled/$DEL_DOMAIN" ]] || \
        run "ln -sf '/etc/nginx/sites-available/$DEL_DOMAIN' '/etc/nginx/sites-enabled/$DEL_DOMAIN'"
    if [[ "$DRY_RUN" != "y" ]]; then
        nginx -t 2>/dev/null && systemctl reload nginx && ok "nginx reloaded" || warn "nginx -t failed."
    fi
}

# ── exec_restore_certbot ────────────────────────────────────
exec_restore_certbot() {
    section "4/7" "RESTORE CERTBOT"
    if [[ -f "$RES_BACKUP_DIR/certbot-live.tar.gz" ]]; then
        run "tar -xzf '$RES_BACKUP_DIR/certbot-live.tar.gz' -C /"
        warn "Cert was REVOKED at delete time. Run: certbot certonly --nginx -d $DEL_DOMAIN -d www.$DEL_DOMAIN"
    fi
}

# ── exec_restore_email ──────────────────────────────────────
exec_restore_email() {
    section "5/7" "RESTORE EMAIL / DKIM"

    # DKIM.
    if [[ -f "$RES_BACKUP_DIR/dkim.tar.gz" ]]; then
        run "tar -xzf '$RES_BACKUP_DIR/dkim.tar.gz' -C /"
        # Reinsert Key/Signing/TrustedHosts entries if absent.
        local key_line="mail._domainkey.$DEL_DOMAIN $DEL_DOMAIN:mail:/etc/opendkim/keys/$DEL_DOMAIN/mail.private"
        local sign_line="*@$DEL_DOMAIN mail._domainkey.$DEL_DOMAIN"
        grep -q "$DEL_DOMAIN" /etc/opendkim/KeyTable       || run "echo '$key_line'  >> /etc/opendkim/KeyTable"
        grep -q "$DEL_DOMAIN" /etc/opendkim/SigningTable   || run "echo '$sign_line' >> /etc/opendkim/SigningTable"
        grep -q "^$DEL_DOMAIN$" /etc/opendkim/TrustedHosts || run "echo '$DEL_DOMAIN'   >> /etc/opendkim/TrustedHosts"
        [[ "$DRY_RUN" != "y" ]] && systemctl reload opendkim 2>/dev/null && ok "opendkim reloaded"
    fi

    # Postfix virtual alias.
    if [[ -n "$DEL_EMAIL_USER" ]] && ! grep -q "@${DEL_DOMAIN}" /etc/postfix/virtual; then
        run "echo 'contact@$DEL_DOMAIN $DEL_EMAIL_USER' >> /etc/postfix/virtual"
        run "postmap /etc/postfix/virtual"
    fi

    # Postfix main.cf virtual_alias_domains.
    if ! grep -qE "^virtual_alias_domains.*${DEL_DOMAIN//./\\.}\\b" /etc/postfix/main.cf; then
        run "sed -i.bak-restore-$$ -E 's/^(virtual_alias_domains[[:space:]]*=[[:space:]]*)(.*)$/\\1$DEL_DOMAIN, \\2/' /etc/postfix/main.cf"
    fi
    [[ "$DRY_RUN" != "y" ]] && systemctl reload postfix 2>/dev/null && ok "postfix reloaded"
}

# ── exec_restore_mailbox ────────────────────────────────────
exec_restore_mailbox() {
    section "6/7" "RESTORE MAILBOX"
    [[ -f "$RES_BACKUP_DIR/maildir.tar.gz" ]] || { info "No mailbox tar — skipping."; return; }
    if [[ -n "$DEL_EMAIL_USER" ]] && ! id "$DEL_EMAIL_USER" &>/dev/null; then
        run "useradd -m -s /usr/sbin/nologin '$DEL_EMAIL_USER'"
    fi
    run "tar -xzf '$RES_BACKUP_DIR/maildir.tar.gz' -C /"
    [[ -n "$DEL_EMAIL_USER" ]] && run "chown -R '$DEL_EMAIL_USER:$DEL_EMAIL_USER' '/home/$DEL_EMAIL_USER'"

    # Dovecot users line — restore from backup or synthesize minimal placeholder.
    if [[ -n "$DEL_EMAIL_USER" ]] && ! grep -q "^${DEL_EMAIL_USER}:" /etc/dovecot/users 2>/dev/null; then
        warn "dovecot /etc/dovecot/users needs manual re-add for $DEL_EMAIL_USER (password hash not in backup)"
    fi
}

# ── exec_restore_verify ─────────────────────────────────────
exec_restore_verify() {
    section "7/7" "VERIFY"
    if [[ -n "$DEL_DB_NAME" ]] && database_exists "$DEL_DB_NAME"; then
        local qtbl; qtbl="$(quote_identifier "${DEL_DB_PREFIX}options")"
        local n; n="$(mysql_admin -N -s -e "SELECT COUNT(*) FROM $DEL_DB_NAME.$qtbl;" 2>/dev/null || echo '?')"
        info "wp_options row count: $n"
    fi
    if [[ -d "$DEL_WEB_ROOT" ]]; then
        info "Docroot back at: $DEL_WEB_ROOT ($(du -sh "$DEL_WEB_ROOT" 2>/dev/null | cut -f1))"
    fi
    info "HTTPS smoke test: curl -sk --resolve $DEL_DOMAIN:443:127.0.0.1 https://$DEL_DOMAIN/  |  head -5"
    ok "Restore complete."
}

# ============================================================
# MAIN
# ============================================================

main() {
    print_header
    check_mysql_health

    # ── PHASE 1: INTAKE ──────────────────────────────────────
    printf '%b\n' "${CYAN}${BOLD}  ╔══════════════════════════════════════════════════╗${NC}"
    printf '%b\n' "${CYAN}${BOLD}  ║  PHASE 1 — CONFIGURATION                        ║${NC}"
    printf '%b\n' "${CYAN}${BOLD}  ║  Answer all questions. Execution starts after.  ║${NC}"
    printf '%b\n' "${CYAN}${BOLD}  ╚══════════════════════════════════════════════════╝${NC}"

    intake_mode

    # ── DELETE branch — separate flow, exits after execution ─
    if [[ "$MODE" == "delete" ]]; then
        intake_mysql_admin
        intake_delete_target
        intake_delete_confirm
        exec_delete_backup
        exec_delete_nginx
        exec_delete_certbot
        exec_delete_email
        exec_delete_mailbox
        exec_delete_database
        exec_delete_files
        exec_delete_logs
        exec_delete_manual_checklist
        printf '%b\n' "${GREEN}${BOLD}  🗑️   Site $DEL_DOMAIN deleted (backup at $DEL_BACKUP_DIR)${NC}"
        exit 0
    fi

    # ── RESTORE branch ───────────────────────────────────────
    if [[ "$MODE" == "restore" ]]; then
        intake_restore_source
        intake_mysql_admin
        intake_restore_confirm
        exec_restore_files
        exec_restore_database
        exec_restore_nginx
        exec_restore_certbot
        exec_restore_email
        exec_restore_mailbox
        exec_restore_verify
        printf '%b\n' "${GREEN}${BOLD}  ♻️   Site $DEL_DOMAIN restored from $RES_BACKUP_DIR${NC}"
        exit 0
    fi

    # ── NEW / COPY branches (existing behaviour) ─────────────
    intake_domain
    [[ "$MODE" == "copy" ]] && intake_copy_source
    intake_database
    intake_email
    intake_options
    intake_mysql_admin

    # ── SUMMARY, EDIT & CONFIRM ───────────────────────────────
    while true; do
        print_summary
        echo ""
        printf '%b\n' "  ${BOLD}[E]${NC}dit a setting   ${BOLD}[L]${NC}aunch now   ${BOLD}[Q]${NC}uit"
        ask "Choice [E/L/Q]:"
        read -r _launch_choice
        case "${_launch_choice,,}" in
            e|edit)  intake_edit_loop ;;
            l|launch) break ;;
            q|quit)  echo "  Cancelled."; exit 0 ;;
            *)       warn "Type E to edit, L to launch, or Q to quit." ;;
        esac
    done

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

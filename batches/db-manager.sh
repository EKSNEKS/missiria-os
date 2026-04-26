#!/usr/bin/env bash

set -u
set -o pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
DB_USER="${DB_USER:-root}"
DB_PASS="${DB_PASS:-}"
MYSQL_BIN="${MYSQL_BIN:-mysql}"
MYSQLDUMP_BIN="${MYSQLDUMP_BIN:-mysqldump}"
DEFAULT_BACKUP_DIR="${DEFAULT_BACKUP_DIR:-/tmp}"
DEFAULT_EXPORT_PATH="${DEFAULT_EXPORT_PATH:-/home/missiria/dump.sql}"
DEFAULT_IMPORT_PATH="${DEFAULT_IMPORT_PATH:-/home/missiria/dump.sql}"
DEFAULT_GRANT_USER="${DEFAULT_GRANT_USER:-missiria}"
DEFAULT_GRANT_HOST="${DEFAULT_GRANT_HOST:-localhost}"

# ─── Colors ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;94m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; NC=""
fi

# ─── Logging ──────────────────────────────────────────────────────────────────
log()   { printf '%s\n' "$*"; }
error() { printf '%b\n' "${RED}Error: $*${NC}" >&2; }
info()  { printf '%b\n' "${BLUE}$*${NC}"; }
ok()    { printf '%b\n' "${GREEN}$*${NC}"; }
warn()  { printf '%b\n' "${YELLOW}$*${NC}"; }

confirm() {
    local answer
    read -r -p "${1:-Proceed?} [y/N]: " answer
    [[ "$answer" == "y" || "$answer" == "Y" ]]
}

# ─── SQL Helpers ──────────────────────────────────────────────────────────────
sql_escape_literal() {
    local v="$1"
    v="${v//\\/\\\\}"; v="${v//\'/\'\'}"
    printf '%s' "$v"
}

quote_identifier() {
    local v="$1"
    v="${v//\`/\`\`}"
    printf '`%s`' "$v"
}

_mysql_auth() {
    if [[ -n "$DB_PASS" ]]; then printf '%s' "-p${DB_PASS}"
    else printf '%s' ""; fi
}
mysql_exec()    {
    local pass_arg; pass_arg="$(_mysql_auth)"
    if [[ -n "$pass_arg" ]]; then "$MYSQL_BIN" -u "$DB_USER" "$pass_arg" "$@"
    else "$MYSQL_BIN" -u "$DB_USER" "$@"; fi
}
mysql_exec_db() {
    local db="$1"; shift
    local pass_arg; pass_arg="$(_mysql_auth)"
    if [[ -n "$pass_arg" ]]; then "$MYSQL_BIN" -u "$DB_USER" "$pass_arg" -D "$db" "$@"
    else "$MYSQL_BIN" -u "$DB_USER" -D "$db" "$@"; fi
}

database_exists() {
    local db_esc result
    db_esc="$(sql_escape_literal "$1")"
    result="$(mysql_exec -N -s -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${db_esc}' LIMIT 1;" 2>/dev/null || true)"
    [[ "$result" == "$1" ]]
}

require_database() {
    if ! database_exists "$1"; then error "Database '$1' not found."; return 1; fi
}

# ─── Database Picker (sets global _DB_SELECTION) ──────────────────────────────
_DB_SELECTION=""
choose_database() {
    local -a list=()
    local choice index db_name

    while IFS= read -r db_name; do
        [[ -n "$db_name" ]] && list+=("$db_name")
    done < <(mysql_exec -N -s -e "SHOW DATABASES;" | grep -vE '^(information_schema|performance_schema|mysql|sys)$')

    if ((${#list[@]} == 0)); then error "No user databases found."; return 1; fi

    log ""; info "Available Databases:"
    for index in "${!list[@]}"; do
        printf '%b[%2d]%b %s\n' "$YELLOW" "$((index + 1))" "$NC" "${list[$index]}"
    done

    read -r -p "Select database number: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then error "Invalid selection."; return 1; fi
    index=$((choice - 1))
    if ((index < 0 || index >= ${#list[@]})); then error "Out of range."; return 1; fi
    _DB_SELECTION="${list[$index]}"
    ok "Selected: ${_DB_SELECTION}"
}

# ─── Backup ───────────────────────────────────────────────────────────────────
_mysqldump() {
    local pass_arg; pass_arg="$(_mysql_auth)"
    if [[ -n "$pass_arg" ]]; then "$MYSQLDUMP_BIN" -u "$DB_USER" "$pass_arg" "$@"
    else "$MYSQLDUMP_BIN" -u "$DB_USER" "$@"; fi
}

backup_database() {
    local db_name="$1" ts backup_file
    ts="$(date +%Y%m%d_%H%M%S)"
    backup_file="${DEFAULT_BACKUP_DIR%/}/${db_name}_${ts}.sql"
    log "Creating backup: $backup_file"
    if _mysqldump "$db_name" > "$backup_file"; then
        ok "Backup saved: $backup_file"; return 0
    fi
    error "Backup failed for '$db_name'."; return 1
}

# ─── Header ───────────────────────────────────────────────────────────────────
print_header() {
    printf '%b\n' "${CYAN}______  ____________________________________________________${NC}"
    printf '%b\n' "${CYAN}___   |/  /___  _/_  ___/_  ___/___  _/__  __ \\___  _/__    |${NC}"
    printf '%b\n' "${CYAN}__  /|_/ / __  / _____ \\_____ \\ __  / __  /_/ /__  / __  /| |${NC}"
    printf '%b\n' "${CYAN}_  /  / / __/ /  ____/ /____/ /__/ /  _  _, _/__/ /  _  ___ |${NC}"
    printf '%b\n' "${CYAN}/_/  /_/  /___/  /____/ /____/ /___/  /_/ |_| /___/  /_/  |_|${NC}"
    printf '%b\n' "${CYAN}                                                             v3${NC}"
    printf '%b\n' "${GREEN}${BOLD}MYSQL DATABASE MANAGER — ALL-IN-ONE${NC}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 1 — DATABASE OPERATIONS
# ═══════════════════════════════════════════════════════════════════════════════

create_database() {
    local db_name db_q grant_access new_user host new_user_esc host_esc do_import dump_file

    info "--- Existing Databases ---"
    mysql_exec -e "SHOW DATABASES;"

    read -r -p "New database name: " db_name
    [[ -z "$db_name" ]] && { error "Name cannot be empty."; return; }
    if database_exists "$db_name"; then error "Database '$db_name' already exists."; return; fi

    db_q="$(quote_identifier "$db_name")"

    read -r -p "Grant ALL privileges to a user? [Y/n]: " grant_access
    grant_access="${grant_access:-y}"

    if [[ "$grant_access" =~ ^[Yy]$ ]]; then
        read -r -p "MySQL user [${DEFAULT_GRANT_USER}]: " new_user; new_user="${new_user:-$DEFAULT_GRANT_USER}"
        read -r -p "Host [${DEFAULT_GRANT_HOST}]: " host; host="${host:-$DEFAULT_GRANT_HOST}"
        new_user_esc="$(sql_escape_literal "$new_user")"
        host_esc="$(sql_escape_literal "$host")"
        if mysql_exec <<EOF
CREATE DATABASE IF NOT EXISTS ${db_q};
GRANT ALL PRIVILEGES ON ${db_q}.* TO '${new_user_esc}'@'${host_esc}';
FLUSH PRIVILEGES;
EOF
        then
            ok "Created '$db_name' and granted ALL to '${new_user}'@'${host}'."
        else
            error "Failed to create database or grant privileges."; return
        fi
    else
        mysql_exec -e "CREATE DATABASE IF NOT EXISTS ${db_q};" || { error "Failed to create database."; return; }
        ok "Created '$db_name'."
    fi

    read -r -p "Import a SQL dump now? [y/N]: " do_import
    if [[ "$do_import" =~ ^[Yy]$ ]]; then
        read -r -p "Dump file path [${DEFAULT_IMPORT_PATH}]: " dump_file
        dump_file="${dump_file:-$DEFAULT_IMPORT_PATH}"
        if [[ ! -f "$dump_file" ]]; then error "File not found: $dump_file"; return; fi
        log "Importing '${dump_file}' into '${db_name}'..."
        if mysql_exec_db "$db_name" < "$dump_file"; then ok "Import successful."; else error "Import failed."; fi
    fi
}

drop_database() {
    local db_name confirm_name db_q
    choose_database || return; db_name="$_DB_SELECTION"
    if confirm "Create a backup before dropping '$db_name'?"; then
        backup_database "$db_name" || return
    fi
    warn "WARNING: This permanently deletes '$db_name'."
    read -r -p "Type the database name to confirm: " confirm_name
    [[ "$confirm_name" != "$db_name" ]] && { warn "Confirmation mismatch. Aborted."; return; }
    db_q="$(quote_identifier "$db_name")"
    mysql_exec -e "DROP DATABASE ${db_q};"
    ok "Database '$db_name' deleted."
}

export_database() {
    local db_name export_file
    choose_database || return; db_name="$_DB_SELECTION"
    read -r -p "Export file path [${DEFAULT_EXPORT_PATH}]: " export_file
    export_file="${export_file:-$DEFAULT_EXPORT_PATH}"
    log "Exporting '${db_name}' to '${export_file}'..."
    if _mysqldump "$db_name" > "$export_file"; then
        ok "Exported '$db_name' -> $export_file"
    else
        error "Export failed."
    fi
}

import_into_existing() {
    local db_name dump_file
    choose_database || return; db_name="$_DB_SELECTION"
    read -r -p "SQL dump file path [${DEFAULT_IMPORT_PATH}]: " dump_file
    dump_file="${dump_file:-$DEFAULT_IMPORT_PATH}"
    [[ ! -f "$dump_file" ]] && { error "File not found: $dump_file"; return; }
    if confirm "Backup '$db_name' before importing?"; then backup_database "$db_name" || return; fi
    confirm "Import '${dump_file}' into '${db_name}'?" || { log "Aborted."; return; }
    log "Importing..."
    if mysql_exec_db "$db_name" < "$dump_file"; then ok "Import successful."; else error "Import failed."; fi
}

backup_single() {
    local db_name
    choose_database || return; db_name="$_DB_SELECTION"
    backup_database "$db_name"
}

backup_all() {
    local -a dbs=()
    local db_name ts backup_file ok_count=0 fail_count=0

    while IFS= read -r db_name; do
        [[ -n "$db_name" ]] && dbs+=("$db_name")
    done < <(mysql_exec -N -s -e "SHOW DATABASES;" | grep -vE '^(information_schema|performance_schema|mysql|sys)$')

    if ((${#dbs[@]} == 0)); then warn "No user databases found."; return; fi
    confirm "Backup all ${#dbs[@]} database(s) to '${DEFAULT_BACKUP_DIR}'?" || { log "Aborted."; return; }

    ts="$(date +%Y%m%d_%H%M%S)"
    for db_name in "${dbs[@]}"; do
        backup_file="${DEFAULT_BACKUP_DIR%/}/${db_name}_${ts}.sql"
        log "Backing up '$db_name'..."
        if _mysqldump "$db_name" > "$backup_file"; then
            ok "  OK: $db_name -> $backup_file"; ok_count=$((ok_count + 1))
        else
            error "  FAILED: $db_name"; fail_count=$((fail_count + 1))
        fi
    done
    ok "Done. Success: ${ok_count} | Failed: ${fail_count}"
}

clone_database() {
    local src dst dst_q tmp
    choose_database || return; src="$_DB_SELECTION"
    read -r -p "Name for the cloned database: " dst
    [[ -z "$dst" ]] && { error "Name cannot be empty."; return; }
    if database_exists "$dst"; then error "Database '$dst' already exists."; return; fi

    dst_q="$(quote_identifier "$dst")"
    tmp="/tmp/${src}_clone_$(date +%Y%m%d_%H%M%S).sql"

    log "Dumping '$src'..."
    _mysqldump "$src" > "$tmp" || { error "Dump failed."; rm -f "$tmp"; return; }
    log "Creating '$dst'..."
    mysql_exec -e "CREATE DATABASE ${dst_q};" || { error "Create failed."; rm -f "$tmp"; return; }
    log "Importing into '$dst'..."
    if mysql_exec_db "$dst" < "$tmp"; then ok "Cloned '$src' -> '$dst'."; else error "Import failed."; fi
    rm -f "$tmp"
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 2 — TABLE OPERATIONS
# ═══════════════════════════════════════════════════════════════════════════════

cleanup_tables() {
    local db_name mode target_prefix plugin_prefix
    local -a tables=()

    choose_database || return; db_name="$_DB_SELECTION"
    log ""; info "--- Tables in '$db_name' ---"
    mysql_exec_db "$db_name" -e "SHOW TABLES;"
    log ""
    log "Cleanup mode:"
    log "  1) Delete tables with a specific prefix"
    log "  2) Delete known WP plugin tables"
    read -r -p "Choice [1-2]: " mode

    case "$mode" in
        1)
            read -r -p "Prefix to delete (e.g., old_): " target_prefix
            [[ -z "$target_prefix" ]] && { error "Prefix cannot be empty."; return; }
            local db_esc prefix_esc
            db_esc="$(sql_escape_literal "$db_name")"
            prefix_esc="$(sql_escape_literal "$target_prefix")"
            while IFS= read -r t; do [[ -n "$t" ]] && tables+=("$t"); done < <(
                mysql_exec -N -s -e "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='${db_esc}' AND TABLE_NAME LIKE CONCAT('${prefix_esc}','%') ORDER BY TABLE_NAME;"
            )
            ;;
        2)
            read -r -p "WP table prefix (e.g., wp_): " plugin_prefix
            [[ -z "$plugin_prefix" ]] && { error "Prefix cannot be empty."; return; }
            local -a plugin_tables=(
                "${plugin_prefix}wpforms_logs" "${plugin_prefix}wpforms_payment_meta"
                "${plugin_prefix}wpforms_payments" "${plugin_prefix}wpforms_tasks_meta"
                "${plugin_prefix}wpmailsmtp_debug_events" "${plugin_prefix}wpmailsmtp_tasks_meta"
                "${plugin_prefix}rank_math_internal_links" "${plugin_prefix}rank_math_internal_meta"
            )
            local db_esc t_esc found
            db_esc="$(sql_escape_literal "$db_name")"
            for t in "${plugin_tables[@]}"; do
                t_esc="$(sql_escape_literal "$t")"
                found="$(mysql_exec -N -s -e "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='${db_esc}' AND TABLE_NAME='${t_esc}' LIMIT 1;")"
                [[ -n "$found" ]] && tables+=("$found")
            done
            ;;
        *) error "Invalid choice."; return ;;
    esac

    if ((${#tables[@]} == 0)); then log "No matching tables found."; return; fi

    warn "--- Tables targeted for deletion ---"
    for t in "${tables[@]}"; do log "  - $t"; done

    if confirm "Backup '$db_name' before deletion?"; then backup_database "$db_name" || return; fi
    confirm "Drop these ${#tables[@]} table(s)?" || { log "Aborted."; return; }

    mysql_exec_db "$db_name" -e "SET FOREIGN_KEY_CHECKS=0;"
    for t in "${tables[@]}"; do
        mysql_exec_db "$db_name" -e "DROP TABLE $(quote_identifier "$t");"
        log "  Dropped: $t"
    done
    mysql_exec_db "$db_name" -e "SET FOREIGN_KEY_CHECKS=1;"
    ok "Cleanup complete."
}

check_repair_tables() {
    local db_name op
    choose_database || return; db_name="$_DB_SELECTION"
    log ""
    log "  1) CHECK tables"
    log "  2) REPAIR tables"
    log "  3) ANALYZE tables"
    read -r -p "Choice [1-3]: " op

    local -a tables=() qts=()
    while IFS= read -r t; do [[ -n "$t" ]] && tables+=("$t"); done < <(mysql_exec_db "$db_name" -N -s -e "SHOW TABLES;")
    if ((${#tables[@]} == 0)); then warn "No tables found."; return; fi
    for t in "${tables[@]}"; do qts+=("$(quote_identifier "$t")"); done
    local target; target="$(IFS=,; printf '%s' "${qts[*]}")"

    case "$op" in
        1) mysql_exec_db "$db_name" -e "CHECK TABLE ${target};" ;;
        2) mysql_exec_db "$db_name" -e "REPAIR TABLE ${target};" ;;
        3) mysql_exec_db "$db_name" -e "ANALYZE TABLE ${target};" ;;
        *) error "Invalid choice." ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 3 — SEARCH & SCAN
# ═══════════════════════════════════════════════════════════════════════════════

global_search_replace() {
    local db_name search replace db_esc s_esc r_esc total=0

    choose_database || return; db_name="$_DB_SELECTION"
    read -r -p "String to find: " search
    [[ -z "$search" ]] && { error "Search string cannot be empty."; return; }
    read -r -p "Replacement (can be empty): " replace

    if confirm "Backup '$db_name' before replacing?"; then backup_database "$db_name" || return; fi
    confirm "Run global search & replace on all text columns in '$db_name'?" || { log "Aborted."; return; }

    db_esc="$(sql_escape_literal "$db_name")"
    s_esc="$(sql_escape_literal "$search")"
    r_esc="$(sql_escape_literal "$replace")"

    local -a cols=()
    while IFS= read -r row; do [[ -n "$row" ]] && cols+=("$row"); done < <(
        mysql_exec -N -B -e "SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='${db_esc}' AND DATA_TYPE IN ('char','varchar','tinytext','text','mediumtext','longtext') ORDER BY TABLE_NAME, ORDINAL_POSITION;"
    )
    if ((${#cols[@]} == 0)); then log "No text columns found."; return; fi

    local tbl col t_q c_q changed
    for row in "${cols[@]}"; do
        IFS=$'\t' read -r tbl col <<< "$row"
        t_q="$(quote_identifier "$tbl")"; c_q="$(quote_identifier "$col")"
        changed="$(mysql_exec_db "$db_name" -N -s -e "UPDATE ${t_q} SET ${c_q}=REPLACE(${c_q},'${s_esc}','${r_esc}') WHERE INSTR(${c_q},'${s_esc}')>0; SELECT ROW_COUNT();" | tail -n1)"
        if [[ "$changed" =~ ^[0-9]+$ ]] && ((changed > 0)); then
            log "  -> ${tbl}.${col}: ${changed} row(s)"; total=$((total + changed))
        fi
    done
    ok "Total rows updated: $total"
}

scan_urls() {
    local db_name db_esc tbl col results

    choose_database || return; db_name="$_DB_SELECTION"
    info "--- Scanning '$db_name' for URLs/domains ---"
    db_esc="$(sql_escape_literal "$db_name")"

    while IFS=$'\t' read -r tbl col; do
        [[ -z "$tbl" || -z "$col" ]] && continue
        results="$(mysql_exec_db "$db_name" -N -e "
            SELECT DISTINCT REGEXP_SUBSTR(\`${col}\`, 'https?://[^/\" >]+')
            FROM \`${tbl}\`
            WHERE \`${col}\` REGEXP 'https?://'
              AND REGEXP_SUBSTR(\`${col}\`, 'https?://[^/\" >]+') IS NOT NULL;
        " 2>/dev/null || true)"
        if [[ -n "$results" ]]; then
            log ""; info "[Table: ${tbl} | Column: ${col}]"
            log "$results"
        fi
    done < <(mysql_exec -N -e "SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='${db_esc}' AND DATA_TYPE IN ('varchar','text','longtext','mediumtext');")

    ok "--- Scan Complete ---"
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 4 — DATABASE INFO
# ═══════════════════════════════════════════════════════════════════════════════

show_db_info() {
    local db_name db_esc
    choose_database || return; db_name="$_DB_SELECTION"
    db_esc="$(sql_escape_literal "$db_name")"

    info "=== Info: $db_name ==="
    log ""
    info "--- Total Size ---"
    mysql_exec -e "SELECT table_schema AS 'Database', ROUND(SUM(data_length+index_length)/1024/1024,2) AS 'Size (MB)' FROM information_schema.tables WHERE table_schema='${db_esc}' GROUP BY table_schema;"
    log ""
    info "--- Table Sizes & Row Counts ---"
    mysql_exec -e "SELECT TABLE_NAME AS 'Table', TABLE_ROWS AS 'Rows', ROUND((DATA_LENGTH+INDEX_LENGTH)/1024/1024,3) AS 'Size (MB)', ENGINE, TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA='${db_esc}' ORDER BY (DATA_LENGTH+INDEX_LENGTH) DESC;"
    log ""
    info "--- Charset / Collation ---"
    mysql_exec -e "SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${db_esc}';"
    log ""
    read -r -p "Press [Enter] to return to main menu..."
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 5 — USER MANAGEMENT
# ═══════════════════════════════════════════════════════════════════════════════

_user_list()   { mysql_exec -e "SELECT User, Host, plugin FROM mysql.user ORDER BY User;"; }

_user_create() {
    local user host pass u_esc h_esc p_esc
    read -r -p "New username: " user; [[ -z "$user" ]] && { error "Username required."; return; }
    read -r -p "Host [localhost]: " host; host="${host:-localhost}"
    read -r -s -p "Password: " pass; echo ""
    u_esc="$(sql_escape_literal "$user")"; h_esc="$(sql_escape_literal "$host")"; p_esc="$(sql_escape_literal "$pass")"
    if mysql_exec -e "CREATE USER '${u_esc}'@'${h_esc}' IDENTIFIED BY '${p_esc}';"; then
        ok "User '${user}'@'${host}' created."
    else error "Failed to create user."; fi
}

_user_drop() {
    local user host u_esc h_esc
    read -r -p "Username to drop: " user; [[ -z "$user" ]] && { error "Username required."; return; }
    read -r -p "Host [localhost]: " host; host="${host:-localhost}"
    confirm "Drop '${user}'@'${host}'?" || { log "Aborted."; return; }
    u_esc="$(sql_escape_literal "$user")"; h_esc="$(sql_escape_literal "$host")"
    if mysql_exec -e "DROP USER '${u_esc}'@'${h_esc}';"; then ok "User dropped."; else error "Failed."; fi
}

_user_grant() {
    local db_name user host db_q u_esc h_esc
    choose_database || return; db_name="$_DB_SELECTION"
    read -r -p "Username: " user; [[ -z "$user" ]] && { error "Username required."; return; }
    read -r -p "Host [localhost]: " host; host="${host:-localhost}"
    db_q="$(quote_identifier "$db_name")"
    u_esc="$(sql_escape_literal "$user")"; h_esc="$(sql_escape_literal "$host")"
    if mysql_exec -e "GRANT ALL PRIVILEGES ON ${db_q}.* TO '${u_esc}'@'${h_esc}'; FLUSH PRIVILEGES;"; then
        ok "Granted ALL on '$db_name' to '${user}'@'${host}'."
    else error "Grant failed."; fi
}

_user_revoke() {
    local db_name user host db_q u_esc h_esc
    choose_database || return; db_name="$_DB_SELECTION"
    read -r -p "Username: " user; [[ -z "$user" ]] && { error "Username required."; return; }
    read -r -p "Host [localhost]: " host; host="${host:-localhost}"
    confirm "Revoke ALL on '$db_name' from '${user}'@'${host}'?" || { log "Aborted."; return; }
    db_q="$(quote_identifier "$db_name")"
    u_esc="$(sql_escape_literal "$user")"; h_esc="$(sql_escape_literal "$host")"
    if mysql_exec -e "REVOKE ALL PRIVILEGES ON ${db_q}.* FROM '${u_esc}'@'${h_esc}'; FLUSH PRIVILEGES;"; then
        ok "Revoked ALL on '$db_name' from '${user}'@'${host}'."
    else error "Revoke failed."; fi
}

_user_grants() {
    local user host u_esc h_esc
    read -r -p "Username: " user; [[ -z "$user" ]] && { error "Username required."; return; }
    read -r -p "Host [localhost]: " host; host="${host:-localhost}"
    u_esc="$(sql_escape_literal "$user")"; h_esc="$(sql_escape_literal "$host")"
    mysql_exec -e "SHOW GRANTS FOR '${u_esc}'@'${h_esc}';"
}

_user_password() {
    local user host pass u_esc h_esc p_esc
    read -r -p "Username: " user; [[ -z "$user" ]] && { error "Username required."; return; }
    read -r -p "Host [localhost]: " host; host="${host:-localhost}"
    read -r -s -p "New password: " pass; echo ""
    u_esc="$(sql_escape_literal "$user")"; h_esc="$(sql_escape_literal "$host")"; p_esc="$(sql_escape_literal "$pass")"
    if mysql_exec -e "ALTER USER '${u_esc}'@'${h_esc}' IDENTIFIED BY '${p_esc}'; FLUSH PRIVILEGES;"; then
        ok "Password updated."
    else error "Failed."; fi
}

user_management() {
    local choice
    while true; do
        log ""; info "--- MySQL User Management ---"
        log "  1) List all users"
        log "  2) Create user"
        log "  3) Drop user"
        log "  4) Grant ALL on a database"
        log "  5) Revoke ALL on a database"
        log "  6) Show grants for a user"
        log "  7) Change user password"
        log "  8) Back"
        read -r -p "Choice [1-8]: " choice
        case "$choice" in
            1) _user_list ;;
            2) _user_create ;;
            3) _user_drop ;;
            4) _user_grant ;;
            5) _user_revoke ;;
            6) _user_grants ;;
            7) _user_password ;;
            8) return ;;
            *) error "Invalid option." ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 6 — FILE TOOLS
# ═══════════════════════════════════════════════════════════════════════════════

mass_file_renamer() {
    local target_dir old_text new_text
    local -a matches=()

    read -r -p "Directory path to scan: " target_dir
    [[ ! -d "$target_dir" ]] && { error "Directory '$target_dir' does not exist."; return; }
    read -r -p "Old string in filenames: " old_text
    [[ -z "$old_text" ]] && { error "Old string cannot be empty."; return; }
    read -r -p "New string: " new_text

    log "Scanning '$target_dir'..."
    while IFS= read -r -d '' path; do matches+=("$path"); done < <(find "$target_dir" -depth -name "*${old_text}*" -print0)
    if ((${#matches[@]} == 0)); then log "No matches found."; return; fi
    log "Found ${#matches[@]} match(es)."
    confirm "Proceed with renaming?" || { log "Aborted."; return; }

    local dir base new_base
    for path in "${matches[@]}"; do
        dir="$(dirname "$path")"; base="$(basename "$path")"
        new_base="${base//$old_text/$new_text}"
        [[ "$base" == "$new_base" ]] && continue
        mv -- "$path" "$dir/$new_base" && log "  Renamed: $base -> $new_base"
    done
    ok "Done."
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 7 — WORDPRESS TOOLS
# ═══════════════════════════════════════════════════════════════════════════════

WP_DB_NAME=""
WP_PREFIX=""

validate_wp_prefix() { [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]; }

wp_table_exists() {
    local db="$1" tbl="$2" db_esc tbl_esc found
    db_esc="$(sql_escape_literal "$db")"; tbl_esc="$(sql_escape_literal "$tbl")"
    found="$(mysql_exec -N -s -e "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='${db_esc}' AND TABLE_NAME='${tbl_esc}' LIMIT 1;" 2>/dev/null || true)"
    [[ -n "$found" ]]
}

require_wp_tables() {
    local -a missing=()
    for suffix in "$@"; do
        wp_table_exists "$WP_DB_NAME" "${WP_PREFIX}${suffix}" || missing+=("${WP_PREFIX}${suffix}")
    done
    if ((${#missing[@]} > 0)); then error "Missing table(s): ${missing[*]}"; return 1; fi
}

get_wp_context() {
    choose_database || return 1
    WP_DB_NAME="$_DB_SELECTION"
    read -r -p "WordPress table prefix (e.g., wp_): " WP_PREFIX
    [[ -z "$WP_PREFIX" ]] && { error "Prefix required."; return 1; }
    validate_wp_prefix "$WP_PREFIX" || { error "Invalid prefix. Use letters, digits, underscore only."; return 1; }
}

maybe_backup_wp() {
    if confirm "Backup '$WP_DB_NAME' before this action?"; then backup_database "$WP_DB_NAME" || return 1; fi
}

_show_posts_where() {
    local where="$1" label="$2" pt rows id title ptype pstatus count=0
    pt="$(quote_identifier "${WP_PREFIX}posts")"
    rows="$(mysql_exec_db "$WP_DB_NAME" -N -B -e "SELECT ID,COALESCE(NULLIF(post_title,''),'(no title)'),post_type,post_status FROM ${pt} WHERE ${where} ORDER BY ID;" 2>/dev/null || true)"
    [[ -z "$rows" ]] && { log "${label}: none found."; return 1; }
    log "${label}:"
    while IFS=$'\t' read -r id title ptype pstatus; do
        log "  - ID ${id} | ${ptype}/${pstatus} | ${title}"; count=$((count + 1))
    done <<< "$rows"
    log "  Total: $count"
}

_show_comments_where() {
    local where="$1" label="$2" ct pt rows cid pid ptitle status count=0
    ct="$(quote_identifier "${WP_PREFIX}comments")"
    pt="$(quote_identifier "${WP_PREFIX}posts")"
    rows="$(mysql_exec_db "$WP_DB_NAME" -N -B -e "SELECT c.comment_ID,c.comment_post_ID,COALESCE(NULLIF(p.post_title,''),'(no title)'),c.comment_approved FROM ${ct} c LEFT JOIN ${pt} p ON p.ID=c.comment_post_ID WHERE ${where} ORDER BY c.comment_ID;" 2>/dev/null || true)"
    [[ -z "$rows" ]] && { log "${label}: none found."; return 1; }
    log "${label}:"
    while IFS=$'\t' read -r cid pid ptitle status; do
        log "  - Comment ${cid} | Post ${pid} | ${status} | ${ptitle}"; count=$((count + 1))
    done <<< "$rows"
    log "  Total: $count"
}

wp_domain_migration() {
    local old new old_esc new_esc ot pt pm r_opt r_guid r_content r_meta
    get_wp_context || return
    require_wp_tables options posts postmeta || return

    read -r -p "OLD domain (e.g., https://old.com): " old
    read -r -p "NEW domain (e.g., https://new.com): " new
    [[ -z "$old" || -z "$new" ]] && { error "Both domains required."; return; }

    old_esc="$(sql_escape_literal "$old")"; new_esc="$(sql_escape_literal "$new")"
    _show_posts_where "INSTR(guid,'${old_esc}')>0 OR INSTR(post_content,'${old_esc}')>0" "Posts to update"
    maybe_backup_wp || return
    confirm "Proceed with full domain migration?" || { log "Aborted."; return; }

    ot="$(quote_identifier "${WP_PREFIX}options")"
    pt="$(quote_identifier "${WP_PREFIX}posts")"
    pm="$(quote_identifier "${WP_PREFIX}postmeta")"

    r_opt="$(mysql_exec_db "$WP_DB_NAME" -N -s -e "UPDATE ${ot} SET option_value=REPLACE(option_value,'${old_esc}','${new_esc}') WHERE option_name IN ('home','siteurl') AND INSTR(option_value,'${old_esc}')>0; SELECT ROW_COUNT();" | tail -n1)"
    r_guid="$(mysql_exec_db "$WP_DB_NAME" -N -s -e "UPDATE ${pt} SET guid=REPLACE(guid,'${old_esc}','${new_esc}') WHERE INSTR(guid,'${old_esc}')>0; SELECT ROW_COUNT();" | tail -n1)"
    r_content="$(mysql_exec_db "$WP_DB_NAME" -N -s -e "UPDATE ${pt} SET post_content=REPLACE(post_content,'${old_esc}','${new_esc}') WHERE INSTR(post_content,'${old_esc}')>0; SELECT ROW_COUNT();" | tail -n1)"
    r_meta="$(mysql_exec_db "$WP_DB_NAME" -N -s -e "UPDATE ${pm} SET meta_value=REPLACE(meta_value,'${old_esc}','${new_esc}') WHERE meta_value NOT LIKE 'a:%' AND meta_value NOT LIKE 'O:%' AND INSTR(meta_value,'${old_esc}')>0; SELECT ROW_COUNT();" | tail -n1)"

    ok "Migration done. options: ${r_opt:-0} | guid: ${r_guid:-0} | post_content: ${r_content:-0} | postmeta: ${r_meta:-0}"
}

wp_replace_post_content() {
    local search replace s_esc r_esc pt changed
    get_wp_context || return
    require_wp_tables posts || return

    read -r -p "Find in post_content: " search
    [[ -z "$search" ]] && { error "Search text cannot be empty."; return; }
    read -r -p "Replace with: " replace
    s_esc="$(sql_escape_literal "$search")"; r_esc="$(sql_escape_literal "$replace")"

    _show_posts_where "INSTR(post_content,'${s_esc}')>0" "Posts to update" || { log "No matches."; return; }
    maybe_backup_wp || return
    confirm "Proceed?" || { log "Aborted."; return; }

    pt="$(quote_identifier "${WP_PREFIX}posts")"
    changed="$(mysql_exec_db "$WP_DB_NAME" -N -s -e "UPDATE ${pt} SET post_content=REPLACE(post_content,'${s_esc}','${r_esc}') WHERE INSTR(post_content,'${s_esc}')>0; SELECT ROW_COUNT();" | tail -n1)"
    ok "Updated ${changed:-0} row(s)."
}

wp_remove_query_param() {
    local raw param p_esc pt before after
    get_wp_context || return
    require_wp_tables posts || return

    read -r -p "Query param to remove [utm_source=chatgpt.com]: " raw
    raw="${raw:-utm_source=chatgpt.com}"
    param="${raw#\?}"; param="${param#&}"
    [[ -z "$param" ]] && { error "Parameter cannot be empty."; return; }
    p_esc="$(sql_escape_literal "$param")"

    _show_posts_where "INSTR(post_content,'${p_esc}')>0" "Posts containing '${param}'" || { log "No matches."; return; }
    maybe_backup_wp || return
    confirm "Remove '${param}' from post_content links?" || { log "Aborted."; return; }

    pt="$(quote_identifier "${WP_PREFIX}posts")"
    before="$(mysql_exec_db "$WP_DB_NAME" -N -s -e "SELECT COUNT(*) FROM ${pt} WHERE INSTR(post_content,'${p_esc}')>0;" | tail -n1)"

    mysql_exec_db "$WP_DB_NAME" -e "
        UPDATE ${pt} SET post_content=REPLACE(post_content,CONCAT('?','${p_esc}','&'),'?') WHERE INSTR(post_content,'${p_esc}')>0;
        UPDATE ${pt} SET post_content=REPLACE(post_content,CONCAT('&','${p_esc}','&'),'&') WHERE INSTR(post_content,'${p_esc}')>0;
        UPDATE ${pt} SET post_content=REPLACE(post_content,CONCAT('?','${p_esc}','\"'),'\"') WHERE INSTR(post_content,'${p_esc}')>0;
        UPDATE ${pt} SET post_content=REPLACE(post_content,CONCAT('&','${p_esc}','\"'),'\"') WHERE INSTR(post_content,'${p_esc}')>0;
        UPDATE ${pt} SET post_content=REPLACE(post_content,CONCAT('?','${p_esc}',CHAR(39)),CHAR(39)) WHERE INSTR(post_content,'${p_esc}')>0;
        UPDATE ${pt} SET post_content=REPLACE(post_content,CONCAT('&','${p_esc}',CHAR(39)),CHAR(39)) WHERE INSTR(post_content,'${p_esc}')>0;
        UPDATE ${pt} SET post_content=REPLACE(post_content,CONCAT('?','${p_esc}','&amp;'),'?') WHERE INSTR(post_content,'${p_esc}')>0;
        UPDATE ${pt} SET post_content=REPLACE(post_content,CONCAT('&','${p_esc}','&amp;'),'&amp;') WHERE INSTR(post_content,'${p_esc}')>0;
        UPDATE ${pt} SET post_content=REPLACE(post_content,CONCAT('&amp;','${p_esc}','&amp;'),'&amp;') WHERE INSTR(post_content,'${p_esc}')>0;
        UPDATE ${pt} SET post_content=REPLACE(post_content,CONCAT('&amp;','${p_esc}','\"'),'\"') WHERE INSTR(post_content,'${p_esc}')>0;
        UPDATE ${pt} SET post_content=REPLACE(post_content,CONCAT('&amp;','${p_esc}',CHAR(39)),CHAR(39)) WHERE INSTR(post_content,'${p_esc}')>0;
        UPDATE ${pt} SET post_content=REPLACE(post_content,CONCAT('?','${p_esc}','&#038;'),'?') WHERE INSTR(post_content,'${p_esc}')>0;
        UPDATE ${pt} SET post_content=REPLACE(post_content,CONCAT('&','${p_esc}','&#038;'),'&#038;') WHERE INSTR(post_content,'${p_esc}')>0;
        UPDATE ${pt} SET post_content=REPLACE(post_content,CONCAT('?','${p_esc}'),'') WHERE INSTR(post_content,'${p_esc}')>0;
        UPDATE ${pt} SET post_content=REPLACE(post_content,CONCAT('&','${p_esc}'),'') WHERE INSTR(post_content,'${p_esc}')>0;
        UPDATE ${pt} SET post_content=REPLACE(post_content,CONCAT('&amp;','${p_esc}'),'') WHERE INSTR(post_content,'${p_esc}')>0;
        UPDATE ${pt} SET post_content=REPLACE(post_content,CONCAT('&#038;','${p_esc}'),'') WHERE INSTR(post_content,'${p_esc}')>0;
    "
    after="$(mysql_exec_db "$WP_DB_NAME" -N -s -e "SELECT COUNT(*) FROM ${pt} WHERE INSTR(post_content,'${p_esc}')>0;" | tail -n1)"
    ok "Done. Rows before: ${before:-0} | after: ${after:-0}"
}

wp_set_siteurl() {
    local url url_esc ot changed
    get_wp_context || return
    require_wp_tables options || return

    read -r -p "New site URL (e.g., https://example.com): " url
    [[ -z "$url" ]] && { error "URL cannot be empty."; return; }
    maybe_backup_wp || return
    confirm "Set siteurl and home to '${url}'?" || { log "Aborted."; return; }

    url_esc="$(sql_escape_literal "$url")"
    ot="$(quote_identifier "${WP_PREFIX}options")"
    changed="$(mysql_exec_db "$WP_DB_NAME" -N -s -e "UPDATE ${ot} SET option_value='${url_esc}' WHERE option_name IN ('siteurl','home'); SELECT ROW_COUNT();" | tail -n1)"
    ok "Updated ${changed:-0} row(s)."
}

wp_clear_transients() {
    get_wp_context || return
    require_wp_tables options || return
    maybe_backup_wp || return
    confirm "Delete all transients?" || { log "Aborted."; return; }

    local ot deleted
    ot="$(quote_identifier "${WP_PREFIX}options")"
    deleted="$(mysql_exec_db "$WP_DB_NAME" -N -s -e "DELETE FROM ${ot} WHERE option_name REGEXP '^_(site_)?transient_'; SELECT ROW_COUNT();" | tail -n1)"
    ok "Deleted ${deleted:-0} transient(s)."
}

wp_delete_revisions() {
    get_wp_context || return
    require_wp_tables posts || return
    _show_posts_where "post_type='revision'" "Revisions to delete" || { log "No revisions found."; return; }
    maybe_backup_wp || return
    confirm "Delete all revisions?" || { log "Aborted."; return; }

    local pt deleted
    pt="$(quote_identifier "${WP_PREFIX}posts")"
    deleted="$(mysql_exec_db "$WP_DB_NAME" -N -s -e "DELETE FROM ${pt} WHERE post_type='revision'; SELECT ROW_COUNT();" | tail -n1)"
    ok "Deleted ${deleted:-0} revision(s)."
}

wp_cleanup_trash_spam() {
    get_wp_context || return
    require_wp_tables posts comments || return

    local has_p=0 has_c=0
    _show_posts_where "post_status IN ('trash','auto-draft')" "Trash/auto-draft posts" && has_p=1
    _show_comments_where "c.comment_approved IN ('spam','trash')" "Spam/trash comments" && has_c=1
    ((has_p == 0 && has_c == 0)) && { log "Nothing to clean."; return; }

    maybe_backup_wp || return
    confirm "Delete trash posts and spam comments?" || { log "Aborted."; return; }

    local pt ct del_p del_c
    pt="$(quote_identifier "${WP_PREFIX}posts")"
    ct="$(quote_identifier "${WP_PREFIX}comments")"
    del_p="$(mysql_exec_db "$WP_DB_NAME" -N -s -e "DELETE FROM ${pt} WHERE post_status IN ('trash','auto-draft'); SELECT ROW_COUNT();" | tail -n1)"
    del_c="$(mysql_exec_db "$WP_DB_NAME" -N -s -e "DELETE FROM ${ct} WHERE comment_approved IN ('spam','trash'); SELECT ROW_COUNT();" | tail -n1)"
    ok "Posts removed: ${del_p:-0} | Comments removed: ${del_c:-0}"
}

wp_cleanup_orphans() {
    get_wp_context || return
    require_wp_tables posts || return
    maybe_backup_wp || return
    confirm "Delete orphan postmeta, commentmeta, term_relationships?" || { log "Aborted."; return; }

    local pt pm cm tr del_pm=0 del_cm=0 del_tr=0
    pt="$(quote_identifier "${WP_PREFIX}posts")"

    if wp_table_exists "$WP_DB_NAME" "${WP_PREFIX}postmeta"; then
        pm="$(quote_identifier "${WP_PREFIX}postmeta")"
        del_pm="$(mysql_exec_db "$WP_DB_NAME" -N -s -e "DELETE pm FROM ${pm} pm LEFT JOIN ${pt} p ON p.ID=pm.post_id WHERE p.ID IS NULL; SELECT ROW_COUNT();" | tail -n1)"
    fi
    if wp_table_exists "$WP_DB_NAME" "${WP_PREFIX}commentmeta" && wp_table_exists "$WP_DB_NAME" "${WP_PREFIX}comments"; then
        cm="$(quote_identifier "${WP_PREFIX}commentmeta")"
        local ct; ct="$(quote_identifier "${WP_PREFIX}comments")"
        del_cm="$(mysql_exec_db "$WP_DB_NAME" -N -s -e "DELETE cm FROM ${cm} cm LEFT JOIN ${ct} c ON c.comment_ID=cm.comment_id WHERE c.comment_ID IS NULL; SELECT ROW_COUNT();" | tail -n1)"
    fi
    if wp_table_exists "$WP_DB_NAME" "${WP_PREFIX}term_relationships"; then
        tr="$(quote_identifier "${WP_PREFIX}term_relationships")"
        del_tr="$(mysql_exec_db "$WP_DB_NAME" -N -s -e "DELETE tr FROM ${tr} tr LEFT JOIN ${pt} p ON p.ID=tr.object_id WHERE p.ID IS NULL; SELECT ROW_COUNT();" | tail -n1)"
    fi
    ok "postmeta: ${del_pm:-0} | commentmeta: ${del_cm:-0} | term_rel: ${del_tr:-0}"
}

_wp_optimize_tables_inline() {
    local db_esc prefix_esc
    db_esc="$(sql_escape_literal "$WP_DB_NAME")"
    prefix_esc="$(sql_escape_literal "$WP_PREFIX")"
    local -a tables=() qts=()
    while IFS= read -r t; do [[ -n "$t" ]] && tables+=("$t"); done < <(
        mysql_exec -N -s -e "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='${db_esc}' AND TABLE_NAME LIKE CONCAT('${prefix_esc}','%') ORDER BY TABLE_NAME;"
    )
    if ((${#tables[@]} == 0)); then warn "No WP tables found."; return; fi
    for t in "${tables[@]}"; do qts+=("$(quote_identifier "$t")"); done
    local target; target="$(IFS=,; printf '%s' "${qts[*]}")"
    mysql_exec_db "$WP_DB_NAME" -e "OPTIMIZE TABLE ${target};"
    ok "Optimized ${#tables[@]} table(s)."
}

wp_optimize_tables() {
    get_wp_context || return
    confirm "Optimize all WP tables with prefix '${WP_PREFIX}'?" || { log "Aborted."; return; }
    _wp_optimize_tables_inline
}

wp_maintenance_bundle() {
    get_wp_context || return
    require_wp_tables options posts comments || return

    _show_posts_where "post_type='revision'" "Revisions"
    _show_posts_where "post_status IN ('trash','auto-draft')" "Trash/auto-draft posts"
    _show_comments_where "c.comment_approved IN ('spam','trash')" "Spam/trash comments"
    maybe_backup_wp || return
    confirm "Run full maintenance bundle?" || { log "Aborted."; return; }

    local ot pt ct pm cm tr
    ot="$(quote_identifier "${WP_PREFIX}options")"
    pt="$(quote_identifier "${WP_PREFIX}posts")"
    ct="$(quote_identifier "${WP_PREFIX}comments")"

    local d_trans d_rev d_posts d_comments d_pm=0 d_cm=0 d_tr=0
    d_trans="$(mysql_exec_db "$WP_DB_NAME" -N -s -e "DELETE FROM ${ot} WHERE option_name REGEXP '^_(site_)?transient_'; SELECT ROW_COUNT();" | tail -n1)"
    d_rev="$(mysql_exec_db "$WP_DB_NAME" -N -s -e "DELETE FROM ${pt} WHERE post_type='revision'; SELECT ROW_COUNT();" | tail -n1)"
    d_posts="$(mysql_exec_db "$WP_DB_NAME" -N -s -e "DELETE FROM ${pt} WHERE post_status IN ('trash','auto-draft'); SELECT ROW_COUNT();" | tail -n1)"
    d_comments="$(mysql_exec_db "$WP_DB_NAME" -N -s -e "DELETE FROM ${ct} WHERE comment_approved IN ('spam','trash'); SELECT ROW_COUNT();" | tail -n1)"

    if wp_table_exists "$WP_DB_NAME" "${WP_PREFIX}postmeta"; then
        pm="$(quote_identifier "${WP_PREFIX}postmeta")"
        d_pm="$(mysql_exec_db "$WP_DB_NAME" -N -s -e "DELETE pm FROM ${pm} pm LEFT JOIN ${pt} p ON p.ID=pm.post_id WHERE p.ID IS NULL; SELECT ROW_COUNT();" | tail -n1)"
    fi
    if wp_table_exists "$WP_DB_NAME" "${WP_PREFIX}commentmeta"; then
        cm="$(quote_identifier "${WP_PREFIX}commentmeta")"
        d_cm="$(mysql_exec_db "$WP_DB_NAME" -N -s -e "DELETE cm FROM ${cm} cm LEFT JOIN ${ct} c ON c.comment_ID=cm.comment_id WHERE c.comment_ID IS NULL; SELECT ROW_COUNT();" | tail -n1)"
    fi
    if wp_table_exists "$WP_DB_NAME" "${WP_PREFIX}term_relationships"; then
        tr="$(quote_identifier "${WP_PREFIX}term_relationships")"
        d_tr="$(mysql_exec_db "$WP_DB_NAME" -N -s -e "DELETE tr FROM ${tr} tr LEFT JOIN ${pt} p ON p.ID=tr.object_id WHERE p.ID IS NULL; SELECT ROW_COUNT();" | tail -n1)"
    fi

    _wp_optimize_tables_inline

    ok "Maintenance bundle complete."
    ok "  Transients: ${d_trans:-0} | Revisions: ${d_rev:-0} | Trash posts: ${d_posts:-0} | Spam comments: ${d_comments:-0}"
    ok "  Orphan postmeta: ${d_pm:-0} | commentmeta: ${d_cm:-0} | term_rel: ${d_tr:-0}"
}

wp_tools_menu() {
    local choice
    while true; do
        log ""; info "--- WordPress Tools (DB: ${WP_DB_NAME:-none}) ---"
        log "  1)  Full domain migration"
        log "  2)  Search & replace in post_content"
        log "  3)  Remove query parameter from links"
        log "  4)  Set siteurl + home"
        log "  5)  Clear transients"
        log "  6)  Delete post revisions"
        log "  7)  Clean trash posts + spam comments"
        log "  8)  Cleanup orphan metadata/relationships"
        log "  9)  Optimize all WP tables"
        log "  10) Maintenance bundle (all-in-one)"
        log "  11) Back"
        read -r -p "Choice [1-11]: " choice
        case "$choice" in
            1)  wp_domain_migration ;;
            2)  wp_replace_post_content ;;
            3)  wp_remove_query_param ;;
            4)  wp_set_siteurl ;;
            5)  wp_clear_transients ;;
            6)  wp_delete_revisions ;;
            7)  wp_cleanup_trash_spam ;;
            8)  wp_cleanup_orphans ;;
            9)  wp_optimize_tables ;;
            10) wp_maintenance_bundle ;;
            11) return ;;
            *)  error "Invalid option." ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN MENU
# ═══════════════════════════════════════════════════════════════════════════════

show_main_menu() {
    clear 2>/dev/null || true
    print_header
    log ""
    printf '%b\n' "${BOLD}${BLUE}─── Database Operations ──────────────────────────────────${NC}"
    printf '%b  1)%b CREATE database  (+ optional user grant + import)\n' "$BLUE" "$NC"
    printf '%b  2)%b DROP database\n' "$BLUE" "$NC"
    printf '%b  3)%b EXPORT database to SQL file\n' "$BLUE" "$NC"
    printf '%b  4)%b IMPORT SQL dump into existing database\n' "$BLUE" "$NC"
    printf '%b  5)%b BACKUP single database\n' "$BLUE" "$NC"
    printf '%b  6)%b BACKUP all databases\n' "$BLUE" "$NC"
    printf '%b  7)%b CLONE / duplicate a database\n' "$BLUE" "$NC"
    printf '%b\n' "${BOLD}${BLUE}─── Table & Data Operations ──────────────────────────────${NC}"
    printf '%b  8)%b CLEANUP tables  (by prefix or plugin list)\n' "$BLUE" "$NC"
    printf '%b  9)%b GLOBAL search & replace across all text columns\n' "$BLUE" "$NC"
    printf '%b 10)%b SCAN database for URLs / domains\n' "$BLUE" "$NC"
    printf '%b 11)%b CHECK / REPAIR / ANALYZE tables\n' "$BLUE" "$NC"
    printf '%b\n' "${BOLD}${BLUE}─── Insights & Administration ────────────────────────────${NC}"
    printf '%b 12)%b DATABASE info  (size, charset, row counts)\n' "$BLUE" "$NC"
    printf '%b 13)%b USER management  (create, drop, grant, revoke, password)\n' "$BLUE" "$NC"
    printf '%b\n' "${BOLD}${BLUE}─── Specialized Tools ────────────────────────────────────${NC}"
    printf '%b 14)%b WORDPRESS tools\n' "$BLUE" "$NC"
    printf '%b 15)%b RENAME physical files in a directory\n' "$BLUE" "$NC"
    printf '%b 16)%b EXIT\n' "$BLUE" "$NC"
    log ""
}

main() {
    local choice
    while true; do
        show_main_menu
        read -r -p "Choice [1-16]: " choice
        case "$choice" in
            1)  create_database ;;
            2)  drop_database ;;
            3)  export_database ;;
            4)  import_into_existing ;;
            5)  backup_single ;;
            6)  backup_all ;;
            7)  clone_database ;;
            8)  cleanup_tables ;;
            9)  global_search_replace ;;
            10) scan_urls ;;
            11) check_repair_tables ;;
            12) show_db_info ;;
            13) user_management ;;
            14) wp_tools_menu ;;
            15) mass_file_renamer ;;
            16) log "Exiting."; return 0 ;;
            *)  error "Invalid option." ;;
        esac
    done
}

main "$@"

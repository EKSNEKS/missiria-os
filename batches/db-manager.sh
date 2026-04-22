#!/usr/bin/env bash

set -u
set -o pipefail

DB_USER="${DB_USER:-root}"
MYSQL_BIN="${MYSQL_BIN:-mysql}"
MYSQLDUMP_BIN="${MYSQLDUMP_BIN:-mysqldump}"
DEFAULT_BACKUP_DIR="${DEFAULT_BACKUP_DIR:-/tmp}"
DEFAULT_EXPORT_PATH="${DEFAULT_EXPORT_PATH:-/home/missiria/dump.sql}"
DEFAULT_IMPORT_PATH="${DEFAULT_IMPORT_PATH:-/home/missiria/dump.sql}"

if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'
    CYAN=$'\033[0;36m'
    NC=$'\033[0m'
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    CYAN=""
    NC=""
fi

log() {
    printf '%s\n' "$*"
}

error() {
    printf '%b\n' "${RED}Error: $*${NC}" >&2
}

print_header() {
    printf '%b\n' "${CYAN}______  ____________________________________________________${NC}"
    printf '%b\n' "${CYAN}___   |/  /___  _/_  ___/_  ___/___  _/__  __ \\___  _/__    |${NC}"
    printf '%b\n' "${CYAN}__  /|_/ / __  / _____ \\_____ \\ __  / __  /_/ /__  / __  /| |${NC}"
    printf '%b\n' "${CYAN}_  /  / / __/ /  ____/ /____/ /__/ /  _  _, _/__/ /  _  ___ |${NC}"
    printf '%b\n' "${CYAN}/_/  /_/  /___/  /____/ /____/ /___/  /_/ |_| /___/  /_/  |_|${NC}"
    printf '%b\n' "${CYAN}                                                             v2${NC}"
    printf '%b\n' "${GREEN}DATABASE MANAGER${NC}"
}

confirm() {
    local message="${1:-Proceed?}"
    local answer
    read -r -p "${message} [y/N]: " answer
    [[ "$answer" == "y" || "$answer" == "Y" ]]
}

sql_escape_literal() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\'/\'\'}"
    printf '%s' "$value"
}

quote_identifier() {
    local value="$1"
    value="${value//\`/\`\`}"
    printf '`%s`' "$value"
}

mysql_exec() {
    "$MYSQL_BIN" -u "$DB_USER" "$@"
}

mysql_exec_db() {
    local db_name="$1"
    shift
    "$MYSQL_BIN" -u "$DB_USER" -D "$db_name" "$@"
}

database_exists() {
    local db_name="$1"
    local db_escaped result
    db_escaped="$(sql_escape_literal "$db_name")"
    result="$(mysql_exec -N -s -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${db_escaped}' LIMIT 1;" 2>/dev/null || true)"
    [[ "$result" == "$db_name" ]]
}

require_database() {
    local db_name="$1"
    if ! database_exists "$db_name"; then
        error "Database '$db_name' not found."
        return 1
    fi
}

backup_database() {
    local db_name="$1"
    local ts backup_file
    ts="$(date +%Y%m%d_%H%M%S)"
    backup_file="${DEFAULT_BACKUP_DIR%/}/${db_name}_${ts}.sql"

    log "Creating backup: $backup_file"
    if "$MYSQLDUMP_BIN" -u "$DB_USER" "$db_name" > "$backup_file"; then
        log "Backup completed."
        return 0
    fi

    error "Backup failed for '$db_name'."
    return 1
}

cleanup_tables() {
    local db_name mode target_prefix plugin_prefix
    local -a tables=()

    read -r -p "Enter the database name: " db_name
    [[ -z "$db_name" ]] && {
        error "Database name is required."
        return
    }
    require_database "$db_name" || return

    log ""
    log "--- Current Tables in $db_name ---"
    mysql_exec_db "$db_name" -e "SHOW TABLES;"
    log "----------------------------------"

    log "Cleanup mode:"
    log "1) DELETE everything with a specific prefix"
    log "2) DELETE known plugin tables only"
    read -r -p "Choice [1-2]: " mode

    case "$mode" in
        1)
            read -r -p "Enter the prefix to delete (e.g., iPe_): " target_prefix
            [[ -z "$target_prefix" ]] && {
                error "Prefix cannot be empty."
                return
            }

            local db_escaped target_prefix_escaped
            db_escaped="$(sql_escape_literal "$db_name")"
            target_prefix_escaped="$(sql_escape_literal "$target_prefix")"

            while IFS= read -r table; do
                [[ -n "$table" ]] && tables+=("$table")
            done < <(
                mysql_exec -N -s -e "
                    SELECT TABLE_NAME
                    FROM information_schema.TABLES
                    WHERE TABLE_SCHEMA='${db_escaped}'
                      AND TABLE_NAME LIKE CONCAT('${target_prefix_escaped}', '%')
                    ORDER BY TABLE_NAME;
                "
            )
            ;;
        2)
            read -r -p "Enter the WP prefix used by plugins (e.g., iPe_): " plugin_prefix
            [[ -z "$plugin_prefix" ]] && {
                error "Prefix cannot be empty."
                return
            }

            local -a plugin_tables=(
                "${plugin_prefix}wpforms_logs"
                "${plugin_prefix}wpforms_payment_meta"
                "${plugin_prefix}wpforms_payments"
                "${plugin_prefix}wpforms_tasks_meta"
                "${plugin_prefix}wpmailsmtp_debug_events"
                "${plugin_prefix}wpmailsmtp_tasks_meta"
                "${plugin_prefix}rank_math_internal_links"
                "${plugin_prefix}rank_math_internal_meta"
            )

            local db_escaped table_name table_escaped found
            db_escaped="$(sql_escape_literal "$db_name")"
            for table_name in "${plugin_tables[@]}"; do
                table_escaped="$(sql_escape_literal "$table_name")"
                found="$(
                    mysql_exec -N -s -e "
                        SELECT TABLE_NAME
                        FROM information_schema.TABLES
                        WHERE TABLE_SCHEMA='${db_escaped}'
                          AND TABLE_NAME='${table_escaped}'
                        LIMIT 1;
                    "
                )"
                [[ -n "$found" ]] && tables+=("$found")
            done
            ;;
        *)
            error "Invalid cleanup mode."
            return
            ;;
    esac

    if ((${#tables[@]} == 0)); then
        log "No matching tables found."
        return
    fi

    log ""
    log "--- TARGETED FOR DELETION ---"
    local table_name
    for table_name in "${tables[@]}"; do
        log " - $table_name"
    done

    if confirm "Create a backup before deletion?"; then
        backup_database "$db_name" || return
    fi

    confirm "Proceed with dropping these tables?" || {
        log "Aborted."
        return
    }

    mysql_exec_db "$db_name" -e "SET FOREIGN_KEY_CHECKS = 0;"
    for table_name in "${tables[@]}"; do
        local table_quoted
        table_quoted="$(quote_identifier "$table_name")"
        mysql_exec_db "$db_name" -e "DROP TABLE ${table_quoted};"
        log "Deleted: $table_name"
    done
    mysql_exec_db "$db_name" -e "SET FOREIGN_KEY_CHECKS = 1;"
    log "Cleanup complete."
}

drop_database() {
    local db_name confirm_name db_quoted
    read -r -p "Enter the database to DELETE: " db_name
    [[ -z "$db_name" ]] && {
        error "Database name is required."
        return
    }
    require_database "$db_name" || return

    if confirm "Create a backup before dropping '$db_name'?"; then
        backup_database "$db_name" || return
    fi

    log "WARNING: You are about to permanently delete database '$db_name'."
    read -r -p "Type the database name again to confirm: " confirm_name
    [[ "$confirm_name" != "$db_name" ]] && {
        log "Confirmation failed. Aborting."
        return
    }

    db_quoted="$(quote_identifier "$db_name")"
    mysql_exec -e "DROP DATABASE ${db_quoted};"
    log "Database '$db_name' has been deleted."
}

create_database() {
    local db_name db_quoted dump_file

    read -r -p "Enter the new database name: " db_name
    [[ -z "$db_name" ]] && {
        error "Database name is required."
        return
    }

    if database_exists "$db_name"; then
        error "Database '$db_name' already exists."
        return
    fi

    db_quoted="$(quote_identifier "$db_name")"
    mysql_exec -e "CREATE DATABASE ${db_quoted};" || {
        error "Failed to create database '$db_name'."
        return
    }
    log "Database '$db_name' has been created."

    read -r -p "SQL dump file path to import [${DEFAULT_IMPORT_PATH}]: " dump_file
    dump_file="${dump_file:-$DEFAULT_IMPORT_PATH}"

    if [[ ! -f "$dump_file" ]]; then
        error "Dump file not found: $dump_file"
        return
    fi

    log "Importing '${dump_file}' into '${db_name}'..."
    if mysql_exec_db "$db_name" < "$dump_file"; then
        log "SUCCESS: Dump imported into '${db_name}'."
    else
        error "Import failed for '${db_name}'."
    fi
}

global_search_replace() {
    local db_name search_text replace_text
    read -r -p "Enter the database name: " db_name
    [[ -z "$db_name" ]] && {
        error "Database name is required."
        return
    }
    require_database "$db_name" || return

    read -r -p "Enter the string to find: " search_text
    [[ -z "$search_text" ]] && {
        error "Search string cannot be empty."
        return
    }
    read -r -p "Enter the replacement string (can be empty): " replace_text

    if confirm "Create a backup before global replace?"; then
        backup_database "$db_name" || return
    fi

    confirm "Run global search & replace on all text columns?" || {
        log "Aborted."
        return
    }

    local db_escaped search_escaped replace_escaped
    db_escaped="$(sql_escape_literal "$db_name")"
    search_escaped="$(sql_escape_literal "$search_text")"
    replace_escaped="$(sql_escape_literal "$replace_text")"

    local -a columns=()
    while IFS= read -r row; do
        [[ -n "$row" ]] && columns+=("$row")
    done < <(
        mysql_exec -N -B -e "
            SELECT TABLE_NAME, COLUMN_NAME
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA='${db_escaped}'
              AND DATA_TYPE IN ('char', 'varchar', 'tinytext', 'text', 'mediumtext', 'longtext')
            ORDER BY TABLE_NAME, ORDINAL_POSITION;
        "
    )

    if ((${#columns[@]} == 0)); then
        log "No text columns found."
        return
    fi

    local total_rows=0 line table_name column_name table_quoted column_quoted changed_rows
    for line in "${columns[@]}"; do
        IFS=$'\t' read -r table_name column_name <<< "$line"
        table_quoted="$(quote_identifier "$table_name")"
        column_quoted="$(quote_identifier "$column_name")"

        changed_rows="$(
            mysql_exec_db "$db_name" -N -s -e "
                UPDATE ${table_quoted}
                SET ${column_quoted} = REPLACE(${column_quoted}, '${search_escaped}', '${replace_escaped}')
                WHERE INSTR(${column_quoted}, '${search_escaped}') > 0;
                SELECT ROW_COUNT();
            " | tail -n1
        )"

        if [[ "$changed_rows" =~ ^[0-9]+$ ]] && ((changed_rows > 0)); then
            log " -> ${table_name}.${column_name}: ${changed_rows} row(s) updated"
            total_rows=$((total_rows + changed_rows))
        fi
    done

    log "Total updated rows: $total_rows"
}

launch_wp_manager() {
    local script_dir wp_script
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    wp_script="${script_dir}/wp-manager.sh"

    if [[ ! -f "$wp_script" ]]; then
        error "WordPress manager not found: $wp_script"
        return 1
    fi

    if [[ -x "$wp_script" ]]; then
        DB_USER="$DB_USER" \
        MYSQL_BIN="$MYSQL_BIN" \
        MYSQLDUMP_BIN="$MYSQLDUMP_BIN" \
        DEFAULT_BACKUP_DIR="$DEFAULT_BACKUP_DIR" \
        "$wp_script"
    else
        DB_USER="$DB_USER" \
        MYSQL_BIN="$MYSQL_BIN" \
        MYSQLDUMP_BIN="$MYSQLDUMP_BIN" \
        DEFAULT_BACKUP_DIR="$DEFAULT_BACKUP_DIR" \
        bash "$wp_script"
    fi
}

mass_file_renamer() {
    local target_dir old_text new_text
    local -a matches=()

    read -r -p "Enter FULL directory path to scan: " target_dir
    if [[ ! -d "$target_dir" ]]; then
        error "Directory '$target_dir' does not exist."
        return
    fi

    read -r -p "Enter the OLD string in filenames: " old_text
    [[ -z "$old_text" ]] && {
        error "Old string cannot be empty."
        return
    }
    read -r -p "Enter the NEW string: " new_text

    log "Scanning '$target_dir' recursively..."
    while IFS= read -r -d '' path; do
        matches+=("$path")
    done < <(find "$target_dir" -depth -name "*${old_text}*" -print0)

    if ((${#matches[@]} == 0)); then
        log "No matching files/directories found."
        return
    fi

    log "Found ${#matches[@]} match(es)."
    confirm "Proceed with renaming?" || {
        log "Aborted."
        return
    }

    local path dir base new_base
    for path in "${matches[@]}"; do
        dir="$(dirname "$path")"
        base="$(basename "$path")"
        new_base="${base//$old_text/$new_text}"
        if [[ "$base" == "$new_base" ]]; then
            continue
        fi
        mv -- "$path" "$dir/$new_base"
        log "Renamed: $base -> $new_base"
    done
    log "Rename operation completed."
}

export_database() {
    local -a db_list=()
    local index selected_db export_file db_num

    while IFS= read -r db_name; do
        [[ -n "$db_name" ]] && db_list+=("$db_name")
    done < <(
        mysql_exec -N -s -e "SHOW DATABASES;" | grep -vE '^(information_schema|performance_schema|mysql|sys)$'
    )

    if ((${#db_list[@]} == 0)); then
        error "No exportable database found."
        return
    fi

    log ""
    log "--- Export Database (Select Number) ---"
    for index in "${!db_list[@]}"; do
        printf '[%2d] %s\n' "$((index + 1))" "${db_list[$index]}"
    done

    read -r -p "Enter the number of the DB to export: " db_num
    if ! [[ "$db_num" =~ ^[0-9]+$ ]]; then
        error "Invalid selection."
        return
    fi

    index=$((db_num - 1))
    if ((index < 0 || index >= ${#db_list[@]})); then
        error "Selection out of range."
        return
    fi

    selected_db="${db_list[$index]}"
    read -r -p "Export file path [${DEFAULT_EXPORT_PATH}]: " export_file
    export_file="${export_file:-$DEFAULT_EXPORT_PATH}"

    log "Running: ${MYSQLDUMP_BIN} -u ${DB_USER} ${selected_db} > ${export_file}"
    if "$MYSQLDUMP_BIN" -u "$DB_USER" "$selected_db" > "$export_file"; then
        log "SUCCESS: Database '${selected_db}' exported to ${export_file}"
    else
        error "Export failed."
    fi
}

show_main_menu() {
    clear 2>/dev/null || true
    print_header
    log ""
    log "${BLUE}--- Master Database & Server Utility ---${NC}"
    mysql_exec -e "SHOW DATABASES;" || error "Could not list databases."
    log "${BLUE}----------------------------------------${NC}"
    log "${BLUE}1)${NC} CLEANUP Tables inside a database (Prefix or Plugins)"
    log "${BLUE}2)${NC} DROP an entire database"
    log "${BLUE}3)${NC} CREATE a database and IMPORT a SQL dump"
    log "${BLUE}4)${NC} SEARCH & REPLACE text across ALL tables (Global)"
    log "${BLUE}5)${NC} LAUNCH WORDPRESS MANAGER (wp-manager.sh)"
    log "${BLUE}6)${NC} RENAME Physical Files in a Directory (e.g., Media Uploads)"
    log "${BLUE}7)${NC} EXPORT a Database (Quick Select by Number)"
    log "${BLUE}8)${NC} EXIT"
}

main() {
    local main_choice
    while true; do
        show_main_menu
        read -r -p "Choice [1-8]: " main_choice

        case "$main_choice" in
            1) cleanup_tables ;;
            2) drop_database ;;
            3) create_database ;;
            4) global_search_replace ;;
            5) launch_wp_manager ;;
            6) mass_file_renamer ;;
            7) export_database ;;
            8)
                log "Exiting."
                return 0
                ;;
            *)
                error "Invalid option."
                ;;
        esac
    done
}

main "$@"

#!/usr/bin/env bash

set -u
set -o pipefail

DB_USER="${DB_USER:-root}"
MYSQL_BIN="${MYSQL_BIN:-mysql}"
MYSQLDUMP_BIN="${MYSQLDUMP_BIN:-mysqldump}"
DEFAULT_BACKUP_DIR="${DEFAULT_BACKUP_DIR:-/tmp}"
DEFAULT_EXPORT_PATH="${DEFAULT_EXPORT_PATH:-/home/missiria/dump.sql}"

log() {
    printf '%s\n' "$*"
}

error() {
    printf 'Error: %s\n' "$*" >&2
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

validate_wp_prefix() {
    local prefix="$1"
    [[ "$prefix" =~ ^[A-Za-z0-9_]+$ ]]
}

wp_table_exists() {
    local db_name="$1"
    local table_name="$2"
    local db_escaped table_escaped found
    db_escaped="$(sql_escape_literal "$db_name")"
    table_escaped="$(sql_escape_literal "$table_name")"
    found="$(
        mysql_exec -N -s -e "
            SELECT TABLE_NAME
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA='${db_escaped}'
              AND TABLE_NAME='${table_escaped}'
            LIMIT 1;
        " 2>/dev/null || true
    )"
    [[ -n "$found" ]]
}

get_wp_context() {
    local db_name prefix
    read -r -p "Enter the WordPress database name: " db_name
    [[ -z "$db_name" ]] && {
        error "Database name is required."
        return 1
    }
    require_database "$db_name" || return 1

    read -r -p "Enter the WordPress table prefix (e.g., wp_): " prefix
    [[ -z "$prefix" ]] && {
        error "Table prefix is required."
        return 1
    }
    if ! validate_wp_prefix "$prefix"; then
        error "Invalid prefix '$prefix'. Allowed chars: letters, numbers, underscore."
        return 1
    fi

    WP_DB_NAME="$db_name"
    WP_PREFIX="$prefix"
    return 0
}

require_wp_core_tables() {
    local db_name="$1"
    local prefix="$2"
    local -a required=("options" "posts" "postmeta")
    local -a missing=()
    local suffix table_name

    for suffix in "${required[@]}"; do
        table_name="${prefix}${suffix}"
        if ! wp_table_exists "$db_name" "$table_name"; then
            missing+=("$table_name")
        fi
    done

    if ((${#missing[@]} > 0)); then
        error "Missing required WordPress table(s): ${missing[*]}"
        return 1
    fi
}

wp_domain_migration() {
    local old_domain new_domain old_escaped new_escaped
    get_wp_context || return
    require_wp_core_tables "$WP_DB_NAME" "$WP_PREFIX" || return

    read -r -p "Enter OLD domain (e.g., https://old.com): " old_domain
    read -r -p "Enter NEW domain (e.g., https://new.com): " new_domain

    [[ -z "$old_domain" || -z "$new_domain" ]] && {
        error "Domains cannot be empty."
        return
    }

    if confirm "Create a backup before WordPress migration?"; then
        backup_database "$WP_DB_NAME" || return
    fi

    confirm "Proceed with domain migration in WordPress tables?" || {
        log "Aborted."
        return
    }

    old_escaped="$(sql_escape_literal "$old_domain")"
    new_escaped="$(sql_escape_literal "$new_domain")"

    local options_table posts_table postmeta_table
    options_table="$(quote_identifier "${WP_PREFIX}options")"
    posts_table="$(quote_identifier "${WP_PREFIX}posts")"
    postmeta_table="$(quote_identifier "${WP_PREFIX}postmeta")"

    local options_rows guid_rows content_rows meta_rows
    options_rows="$(
        mysql_exec_db "$WP_DB_NAME" -N -s -e "
            UPDATE ${options_table}
            SET option_value = REPLACE(option_value, '${old_escaped}', '${new_escaped}')
            WHERE option_name IN ('home', 'siteurl')
              AND INSTR(option_value, '${old_escaped}') > 0;
            SELECT ROW_COUNT();
        " | tail -n1
    )"

    guid_rows="$(
        mysql_exec_db "$WP_DB_NAME" -N -s -e "
            UPDATE ${posts_table}
            SET guid = REPLACE(guid, '${old_escaped}', '${new_escaped}')
            WHERE INSTR(guid, '${old_escaped}') > 0;
            SELECT ROW_COUNT();
        " | tail -n1
    )"

    content_rows="$(
        mysql_exec_db "$WP_DB_NAME" -N -s -e "
            UPDATE ${posts_table}
            SET post_content = REPLACE(post_content, '${old_escaped}', '${new_escaped}')
            WHERE INSTR(post_content, '${old_escaped}') > 0;
            SELECT ROW_COUNT();
        " | tail -n1
    )"

    meta_rows="$(
        mysql_exec_db "$WP_DB_NAME" -N -s -e "
            UPDATE ${postmeta_table}
            SET meta_value = REPLACE(meta_value, '${old_escaped}', '${new_escaped}')
            WHERE meta_value NOT LIKE 'a:%'
              AND meta_value NOT LIKE 'O:%'
              AND INSTR(meta_value, '${old_escaped}') > 0;
            SELECT ROW_COUNT();
        " | tail -n1
    )"

    log "WordPress migration completed."
    log " - options (home/siteurl): ${options_rows:-0} row(s)"
    log " - posts.guid: ${guid_rows:-0} row(s)"
    log " - posts.post_content: ${content_rows:-0} row(s)"
    log " - postmeta.meta_value (non-serialized only): ${meta_rows:-0} row(s)"
}

wp_replace_post_content() {
    local search_text replace_text search_escaped replace_escaped
    get_wp_context || return
    if ! wp_table_exists "$WP_DB_NAME" "${WP_PREFIX}posts"; then
        error "Missing posts table: ${WP_PREFIX}posts"
        return
    fi

    read -r -p "Find in post_content: " search_text
    [[ -z "$search_text" ]] && {
        error "Search text cannot be empty."
        return
    }
    read -r -p "Replace with: " replace_text

    if confirm "Create a backup before replacing post_content?"; then
        backup_database "$WP_DB_NAME" || return
    fi

    confirm "Proceed with post_content replacement?" || {
        log "Aborted."
        return
    }

    search_escaped="$(sql_escape_literal "$search_text")"
    replace_escaped="$(sql_escape_literal "$replace_text")"

    local posts_table changed_rows
    posts_table="$(quote_identifier "${WP_PREFIX}posts")"
    changed_rows="$(
        mysql_exec_db "$WP_DB_NAME" -N -s -e "
            UPDATE ${posts_table}
            SET post_content = REPLACE(post_content, '${search_escaped}', '${replace_escaped}')
            WHERE INSTR(post_content, '${search_escaped}') > 0;
            SELECT ROW_COUNT();
        " | tail -n1
    )"

    log "post_content replacement completed: ${changed_rows:-0} row(s) updated."
}

wp_remove_param_in_post_content() {
    local raw_param param_to_remove param_escaped
    get_wp_context || return
    if ! wp_table_exists "$WP_DB_NAME" "${WP_PREFIX}posts"; then
        error "Missing posts table: ${WP_PREFIX}posts"
        return
    fi

    read -r -p "Query parameter to remove [utm_source=chatgpt.com]: " raw_param
    raw_param="${raw_param:-utm_source=chatgpt.com}"
    raw_param="${raw_param#\?}"
    raw_param="${raw_param#&}"
    param_to_remove="$raw_param"

    [[ -z "$param_to_remove" ]] && {
        error "Parameter cannot be empty."
        return
    }

    if confirm "Create a backup before URL parameter cleanup?"; then
        backup_database "$WP_DB_NAME" || return
    fi

    confirm "Proceed with post_content link cleanup for '${param_to_remove}'?" || {
        log "Aborted."
        return
    }

    local posts_table before_count after_count
    posts_table="$(quote_identifier "${WP_PREFIX}posts")"
    param_escaped="$(sql_escape_literal "$param_to_remove")"

    before_count="$(
        mysql_exec_db "$WP_DB_NAME" -N -s -e "
            SELECT COUNT(*)
            FROM ${posts_table}
            WHERE INSTR(post_content, '${param_escaped}') > 0;
        " | tail -n1
    )"

    mysql_exec_db "$WP_DB_NAME" -e "
        UPDATE ${posts_table}
        SET post_content = REPLACE(post_content, CONCAT('?', '${param_escaped}', '&'), '?')
        WHERE INSTR(post_content, '${param_escaped}') > 0;

        UPDATE ${posts_table}
        SET post_content = REPLACE(post_content, CONCAT('&', '${param_escaped}', '&'), '&')
        WHERE INSTR(post_content, '${param_escaped}') > 0;

        UPDATE ${posts_table}
        SET post_content = REPLACE(post_content, CONCAT('?', '${param_escaped}', '\"'), '\"')
        WHERE INSTR(post_content, '${param_escaped}') > 0;

        UPDATE ${posts_table}
        SET post_content = REPLACE(post_content, CONCAT('&', '${param_escaped}', '\"'), '\"')
        WHERE INSTR(post_content, '${param_escaped}') > 0;

        UPDATE ${posts_table}
        SET post_content = REPLACE(post_content, CONCAT('?', '${param_escaped}', CHAR(39)), CHAR(39))
        WHERE INSTR(post_content, '${param_escaped}') > 0;

        UPDATE ${posts_table}
        SET post_content = REPLACE(post_content, CONCAT('&', '${param_escaped}', CHAR(39)), CHAR(39))
        WHERE INSTR(post_content, '${param_escaped}') > 0;

        UPDATE ${posts_table}
        SET post_content = REPLACE(post_content, CONCAT('?', '${param_escaped}', '&amp;'), '?')
        WHERE INSTR(post_content, '${param_escaped}') > 0;

        UPDATE ${posts_table}
        SET post_content = REPLACE(post_content, CONCAT('&', '${param_escaped}', '&amp;'), '&amp;')
        WHERE INSTR(post_content, '${param_escaped}') > 0;

        UPDATE ${posts_table}
        SET post_content = REPLACE(post_content, CONCAT('&amp;', '${param_escaped}', '&amp;'), '&amp;')
        WHERE INSTR(post_content, '${param_escaped}') > 0;

        UPDATE ${posts_table}
        SET post_content = REPLACE(post_content, CONCAT('&amp;', '${param_escaped}', '\"'), '\"')
        WHERE INSTR(post_content, '${param_escaped}') > 0;

        UPDATE ${posts_table}
        SET post_content = REPLACE(post_content, CONCAT('&amp;', '${param_escaped}', CHAR(39)), CHAR(39))
        WHERE INSTR(post_content, '${param_escaped}') > 0;

        UPDATE ${posts_table}
        SET post_content = REPLACE(post_content, CONCAT('?', '${param_escaped}'), '')
        WHERE INSTR(post_content, '${param_escaped}') > 0;

        UPDATE ${posts_table}
        SET post_content = REPLACE(post_content, CONCAT('&', '${param_escaped}'), '')
        WHERE INSTR(post_content, '${param_escaped}') > 0;

        UPDATE ${posts_table}
        SET post_content = REPLACE(post_content, CONCAT('&amp;', '${param_escaped}'), '')
        WHERE INSTR(post_content, '${param_escaped}') > 0;
    "

    after_count="$(
        mysql_exec_db "$WP_DB_NAME" -N -s -e "
            SELECT COUNT(*)
            FROM ${posts_table}
            WHERE INSTR(post_content, '${param_escaped}') > 0;
        " | tail -n1
    )"

    log "WordPress post_content query cleanup completed."
    log " - Rows containing '${param_to_remove}' before: ${before_count:-0}"
    log " - Rows containing '${param_to_remove}' after : ${after_count:-0}"
    log "Trailing quote patterns are handled for both single and double quotes."
}

wordpress_batch_menu() {
    local choice
    while true; do
        log ""
        log "--- WORDPRESS BATCH SHELL ---"
        log "1) Domain migration (siteurl, home, guid, content, postmeta)"
        log "2) Search & replace in post_content only"
        log "3) Remove query parameter from post_content links"
        log "4) Back to main menu"
        read -r -p "Choice [1-4]: " choice

        case "$choice" in
            1) wp_domain_migration ;;
            2) wp_replace_post_content ;;
            3) wp_remove_param_in_post_content ;;
            4) return ;;
            *) error "Invalid WordPress batch option." ;;
        esac
    done
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
    log ""
    log "--- Master Database & Server Utility ---"
    mysql_exec -e "SHOW DATABASES;" || error "Could not list databases."
    log "----------------------------------------"
    log "1) CLEANUP Tables inside a database (Prefix or Plugins)"
    log "2) DROP an entire database"
    log "3) SEARCH & REPLACE text across ALL tables (Global)"
    log "4) WORDPRESS BATCH SHELL (migration, post_content tools)"
    log "5) RENAME Physical Files in a Directory (e.g., Media Uploads)"
    log "6) EXPORT a Database (Quick Select by Number)"
    log "7) EXIT"
}

main() {
    local main_choice
    while true; do
        show_main_menu
        read -r -p "Choice [1-7]: " main_choice

        case "$main_choice" in
            1) cleanup_tables ;;
            2) drop_database ;;
            3) global_search_replace ;;
            4) wordpress_batch_menu ;;
            5) mass_file_renamer ;;
            6) export_database ;;
            7)
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

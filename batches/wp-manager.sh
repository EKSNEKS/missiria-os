#!/usr/bin/env bash

set -u
set -o pipefail

DB_USER="${DB_USER:-missiria}"
MYSQL_BIN="${MYSQL_BIN:-mysql}"
MYSQLDUMP_BIN="${MYSQLDUMP_BIN:-mysqldump}"
DEFAULT_BACKUP_DIR="${DEFAULT_BACKUP_DIR:-/tmp}"

WP_DB_NAME=""
WP_PREFIX=""
SELECTED_DB=""

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
    result="$(
        mysql_exec -N -s -e "
            SELECT SCHEMA_NAME
            FROM information_schema.SCHEMATA
            WHERE SCHEMA_NAME='${db_escaped}'
            LIMIT 1;
        " 2>/dev/null || true
    )"
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
    backup_file="${DEFAULT_BACKUP_DIR%/}/${db_name}_wp_${ts}.sql"

    log "Creating backup: $backup_file"
    if "$MYSQLDUMP_BIN" -u "$DB_USER" "$db_name" > "$backup_file"; then
        log "Backup completed."
        return 0
    fi

    error "Backup failed for '$db_name'."
    return 1
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

require_wp_tables() {
    local suffix table_name
    local -a missing=()
    for suffix in "$@"; do
        table_name="${WP_PREFIX}${suffix}"
        if ! wp_table_exists "$WP_DB_NAME" "$table_name"; then
            missing+=("$table_name")
        fi
    done

    if ((${#missing[@]} > 0)); then
        error "Missing required table(s): ${missing[*]}"
        return 1
    fi
}

print_header() {
    printf '%b\n' "${CYAN}______  ____________________________________________________${NC}"
    printf '%b\n' "${CYAN}___   |/  /___  _/_  ___/_  ___/___  _/__  __ \\___  _/__    |${NC}"
    printf '%b\n' "${CYAN}__  /|_/ / __  / _____ \\_____ \\ __  / __  /_/ /__  / __  /| |${NC}"
    printf '%b\n' "${CYAN}_  /  / / __/ /  ____/ /____/ /__/ /  _  _, _/__/ /  _  ___ |${NC}"
    printf '%b\n' "${CYAN}/_/  /_/  /___/  /____/ /____/ /___/  /_/ |_| /___/  /_/  |_|${NC}"
    printf '%b\n' "${CYAN}                                                             v2${NC}"
    printf '%b\n' "${GREEN}WORDPRESS DATABASE MANAGER${NC}"
}

choose_database_by_number() {
    local -a db_list=()
    local db_name choice index

    while IFS= read -r db_name; do
        [[ -n "$db_name" ]] && db_list+=("$db_name")
    done < <(
        mysql_exec -N -s -e "SHOW DATABASES;" | grep -vE '^(information_schema|performance_schema|mysql|sys)$'
    )

    if ((${#db_list[@]} == 0)); then
        error "No non-system databases found."
        return 1
    fi

    log ""
    log "${BLUE}Available Databases:${NC}"
    for index in "${!db_list[@]}"; do
        printf '%b[%2d]%b %s\n' "$YELLOW" "$((index + 1))" "$NC" "${db_list[$index]}"
    done

    read -r -p "Select database number: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        error "Invalid selection."
        return 1
    fi

    index=$((choice - 1))
    if ((index < 0 || index >= ${#db_list[@]})); then
        error "Selection out of range."
        return 1
    fi

    SELECTED_DB="${db_list[$index]}"
    log "Selected database: ${GREEN}${SELECTED_DB}${NC}"
}

show_post_details_where() {
    local where_clause="$1"
    local label="$2"
    local posts_table rows
    local id title post_type post_status count=0

    posts_table="$(quote_identifier "${WP_PREFIX}posts")"
    rows="$(
        mysql_exec_db "$WP_DB_NAME" -N -B -e "
            SELECT
                ID,
                COALESCE(NULLIF(post_title, ''), '(no title)') AS post_title,
                post_type,
                post_status
            FROM ${posts_table}
            WHERE ${where_clause}
            ORDER BY ID;
        "
    )"

    if [[ -z "$rows" ]]; then
        log "${label}: no matching posts."
        return 1
    fi

    log "${label}:"
    while IFS=$'\t' read -r id title post_type post_status; do
        log " - ID ${id} | ${post_type}/${post_status} | ${title}"
        count=$((count + 1))
    done <<< "$rows"
    log "Total posts listed: ${count}"
    return 0
}

show_comment_details_where() {
    local where_clause="$1"
    local label="$2"
    local comments_table posts_table rows
    local comment_id post_id post_title status count=0

    comments_table="$(quote_identifier "${WP_PREFIX}comments")"
    posts_table="$(quote_identifier "${WP_PREFIX}posts")"
    rows="$(
        mysql_exec_db "$WP_DB_NAME" -N -B -e "
            SELECT
                c.comment_ID,
                c.comment_post_ID,
                COALESCE(NULLIF(p.post_title, ''), '(no title)') AS post_title,
                c.comment_approved
            FROM ${comments_table} c
            LEFT JOIN ${posts_table} p ON p.ID = c.comment_post_ID
            WHERE ${where_clause}
            ORDER BY c.comment_ID;
        "
    )"

    if [[ -z "$rows" ]]; then
        log "${label}: no matching comments."
        return 1
    fi

    log "${label}:"
    while IFS=$'\t' read -r comment_id post_id post_title status; do
        log " - Comment ${comment_id} | Post ${post_id} | ${status} | ${post_title}"
        count=$((count + 1))
    done <<< "$rows"
    log "Total comments listed: ${count}"
    return 0
}

get_wp_context() {
    local db_name prefix
    choose_database_by_number || return 1
    db_name="$SELECTED_DB"
    require_database "$db_name" || return 1

    read -r -p "Enter WordPress table prefix (e.g., wp_): " prefix
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
}

maybe_backup_wp_db() {
    if confirm "Create a backup before running this action?"; then
        backup_database "$WP_DB_NAME" || return 1
    fi
}

wp_domain_migration() {
    local old_domain new_domain old_escaped new_escaped
    get_wp_context || return
    require_wp_tables options posts postmeta || return

    read -r -p "Enter OLD domain (e.g., https://old.com): " old_domain
    read -r -p "Enter NEW domain (e.g., https://new.com): " new_domain
    [[ -z "$old_domain" || -z "$new_domain" ]] && {
        error "Both domains are required."
        return
    }

    old_escaped="$(sql_escape_literal "$old_domain")"
    new_escaped="$(sql_escape_literal "$new_domain")"

    show_post_details_where \
        "INSTR(guid, '${old_escaped}') > 0 OR INSTR(post_content, '${old_escaped}') > 0" \
        "Posts that will be updated (guid/post_content)"

    maybe_backup_wp_db || return
    confirm "Proceed with full WordPress domain migration?" || {
        log "Aborted."
        return
    }

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
    require_wp_tables posts || return

    read -r -p "Find in post_content: " search_text
    [[ -z "$search_text" ]] && {
        error "Search text cannot be empty."
        return
    }
    read -r -p "Replace with: " replace_text

    search_escaped="$(sql_escape_literal "$search_text")"
    replace_escaped="$(sql_escape_literal "$replace_text")"

    if ! show_post_details_where \
        "INSTR(post_content, '${search_escaped}') > 0" \
        "Posts that will be updated in post_content"; then
        log "No post_content rows matched '${search_text}'."
        return
    fi

    maybe_backup_wp_db || return
    confirm "Proceed with post_content replacement?" || {
        log "Aborted."
        return
    }

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
    require_wp_tables posts || return

    read -r -p "Query parameter to remove [utm_source=chatgpt.com]: " raw_param
    raw_param="${raw_param:-utm_source=chatgpt.com}"
    raw_param="${raw_param#\?}"
    raw_param="${raw_param#&}"
    param_to_remove="$raw_param"

    [[ -z "$param_to_remove" ]] && {
        error "Parameter cannot be empty."
        return
    }

    param_escaped="$(sql_escape_literal "$param_to_remove")"
    if ! show_post_details_where \
        "INSTR(post_content, '${param_escaped}') > 0" \
        "Posts that contain '${param_to_remove}' in post_content"; then
        log "No post_content rows matched parameter '${param_to_remove}'."
        return
    fi

    maybe_backup_wp_db || return
    confirm "Proceed with post_content link cleanup for '${param_to_remove}'?" || {
        log "Aborted."
        return
    }

    local posts_table before_count after_count
    posts_table="$(quote_identifier "${WP_PREFIX}posts")"

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
        SET post_content = REPLACE(post_content, CONCAT('?', '${param_escaped}', '&#038;'), '?')
        WHERE INSTR(post_content, '${param_escaped}') > 0;

        UPDATE ${posts_table}
        SET post_content = REPLACE(post_content, CONCAT('&', '${param_escaped}', '&#038;'), '&#038;')
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

        UPDATE ${posts_table}
        SET post_content = REPLACE(post_content, CONCAT('&#038;', '${param_escaped}'), '')
        WHERE INSTR(post_content, '${param_escaped}') > 0;
    "

    after_count="$(
        mysql_exec_db "$WP_DB_NAME" -N -s -e "
            SELECT COUNT(*)
            FROM ${posts_table}
            WHERE INSTR(post_content, '${param_escaped}') > 0;
        " | tail -n1
    )"

    log "post_content query cleanup completed."
    log " - Rows containing '${param_to_remove}' before: ${before_count:-0}"
    log " - Rows containing '${param_to_remove}' after : ${after_count:-0}"
    log "Trailing quote patterns are handled for single/double quotes."
}

wp_set_siteurl_home() {
    local new_url new_url_escaped
    get_wp_context || return
    require_wp_tables options || return

    read -r -p "Enter NEW site URL (e.g., https://example.com): " new_url
    [[ -z "$new_url" ]] && {
        error "URL cannot be empty."
        return
    }

    maybe_backup_wp_db || return
    confirm "Set both 'siteurl' and 'home' to '${new_url}'?" || {
        log "Aborted."
        return
    }

    new_url_escaped="$(sql_escape_literal "$new_url")"
    local options_table changed_rows
    options_table="$(quote_identifier "${WP_PREFIX}options")"

    changed_rows="$(
        mysql_exec_db "$WP_DB_NAME" -N -s -e "
            UPDATE ${options_table}
            SET option_value='${new_url_escaped}'
            WHERE option_name IN ('siteurl', 'home');
            SELECT ROW_COUNT();
        " | tail -n1
    )"

    log "siteurl/home update completed: ${changed_rows:-0} row(s) changed."
}

wp_clear_transients() {
    get_wp_context || return
    require_wp_tables options || return
    maybe_backup_wp_db || return

    confirm "Delete all transients and site transients?" || {
        log "Aborted."
        return
    }

    local options_table deleted_rows
    options_table="$(quote_identifier "${WP_PREFIX}options")"
    deleted_rows="$(
        mysql_exec_db "$WP_DB_NAME" -N -s -e "
            DELETE FROM ${options_table}
            WHERE option_name REGEXP '^_(site_)?transient_';
            SELECT ROW_COUNT();
        " | tail -n1
    )"

    log "Transient cleanup completed: ${deleted_rows:-0} row(s) deleted."
}

wp_delete_revisions() {
    get_wp_context || return
    require_wp_tables posts || return

    if ! show_post_details_where "post_type='revision'" "Post revisions selected for deletion"; then
        log "No revisions found."
        return
    fi

    maybe_backup_wp_db || return

    confirm "Delete all post revisions?" || {
        log "Aborted."
        return
    }

    local posts_table deleted_rows
    posts_table="$(quote_identifier "${WP_PREFIX}posts")"
    deleted_rows="$(
        mysql_exec_db "$WP_DB_NAME" -N -s -e "
            DELETE FROM ${posts_table}
            WHERE post_type='revision';
            SELECT ROW_COUNT();
        " | tail -n1
    )"

    log "Revision cleanup completed: ${deleted_rows:-0} row(s) deleted."
}

wp_cleanup_trash_and_spam() {
    get_wp_context || return
    require_wp_tables posts comments || return

    local has_posts=0 has_comments=0
    if show_post_details_where "post_status IN ('trash', 'auto-draft')" "Posts selected for deletion"; then
        has_posts=1
    fi
    if show_comment_details_where "c.comment_approved IN ('spam', 'trash')" "Comments selected for deletion"; then
        has_comments=1
    fi
    if ((has_posts == 0 && has_comments == 0)); then
        log "No trash/auto-draft posts or spam/trash comments found."
        return
    fi

    maybe_backup_wp_db || return

    confirm "Delete trash/auto-draft posts and spam/trash comments?" || {
        log "Aborted."
        return
    }

    local posts_table comments_table deleted_posts deleted_comments
    posts_table="$(quote_identifier "${WP_PREFIX}posts")"
    comments_table="$(quote_identifier "${WP_PREFIX}comments")"

    deleted_posts="$(
        mysql_exec_db "$WP_DB_NAME" -N -s -e "
            DELETE FROM ${posts_table}
            WHERE post_status IN ('trash', 'auto-draft');
            SELECT ROW_COUNT();
        " | tail -n1
    )"
    deleted_comments="$(
        mysql_exec_db "$WP_DB_NAME" -N -s -e "
            DELETE FROM ${comments_table}
            WHERE comment_approved IN ('spam', 'trash');
            SELECT ROW_COUNT();
        " | tail -n1
    )"

    log "Trash/spam cleanup completed."
    log " - Posts removed   : ${deleted_posts:-0}"
    log " - Comments removed: ${deleted_comments:-0}"
}

wp_cleanup_orphans() {
    get_wp_context || return
    require_wp_tables posts || return
    maybe_backup_wp_db || return

    confirm "Delete orphan postmeta/commentmeta/term relationships?" || {
        log "Aborted."
        return
    }

    local postmeta_deleted=0 commentmeta_deleted=0 relationships_deleted=0
    local posts_table postmeta_table comments_table commentmeta_table term_rel_table

    posts_table="$(quote_identifier "${WP_PREFIX}posts")"
    comments_table="$(quote_identifier "${WP_PREFIX}comments")"

    if wp_table_exists "$WP_DB_NAME" "${WP_PREFIX}postmeta"; then
        postmeta_table="$(quote_identifier "${WP_PREFIX}postmeta")"
        postmeta_deleted="$(
            mysql_exec_db "$WP_DB_NAME" -N -s -e "
                DELETE pm FROM ${postmeta_table} pm
                LEFT JOIN ${posts_table} p ON p.ID = pm.post_id
                WHERE p.ID IS NULL;
                SELECT ROW_COUNT();
            " | tail -n1
        )"
    fi

    if wp_table_exists "$WP_DB_NAME" "${WP_PREFIX}commentmeta" && wp_table_exists "$WP_DB_NAME" "${WP_PREFIX}comments"; then
        commentmeta_table="$(quote_identifier "${WP_PREFIX}commentmeta")"
        commentmeta_deleted="$(
            mysql_exec_db "$WP_DB_NAME" -N -s -e "
                DELETE cm FROM ${commentmeta_table} cm
                LEFT JOIN ${comments_table} c ON c.comment_ID = cm.comment_id
                WHERE c.comment_ID IS NULL;
                SELECT ROW_COUNT();
            " | tail -n1
        )"
    fi

    if wp_table_exists "$WP_DB_NAME" "${WP_PREFIX}term_relationships"; then
        term_rel_table="$(quote_identifier "${WP_PREFIX}term_relationships")"
        relationships_deleted="$(
            mysql_exec_db "$WP_DB_NAME" -N -s -e "
                DELETE tr FROM ${term_rel_table} tr
                LEFT JOIN ${posts_table} p ON p.ID = tr.object_id
                WHERE p.ID IS NULL;
                SELECT ROW_COUNT();
            " | tail -n1
        )"
    fi

    log "Orphan cleanup completed."
    log " - postmeta rows removed        : ${postmeta_deleted:-0}"
    log " - commentmeta rows removed     : ${commentmeta_deleted:-0}"
    log " - term_relationships removed   : ${relationships_deleted:-0}"
}

wp_optimize_tables() {
    get_wp_context || return

    local db_escaped prefix_escaped
    db_escaped="$(sql_escape_literal "$WP_DB_NAME")"
    prefix_escaped="$(sql_escape_literal "$WP_PREFIX")"

    local -a tables=()
    while IFS= read -r table_name; do
        [[ -n "$table_name" ]] && tables+=("$table_name")
    done < <(
        mysql_exec -N -s -e "
            SELECT TABLE_NAME
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA='${db_escaped}'
              AND TABLE_NAME LIKE CONCAT('${prefix_escaped}', '%')
            ORDER BY TABLE_NAME;
        "
    )

    if ((${#tables[@]} == 0)); then
        error "No WordPress tables found with prefix '${WP_PREFIX}'."
        return
    fi

    confirm "Optimize ${#tables[@]} table(s) now?" || {
        log "Aborted."
        return
    }

    local -a quoted_tables=()
    local table_name
    for table_name in "${tables[@]}"; do
        quoted_tables+=("$(quote_identifier "$table_name")")
    done

    local optimize_target
    optimize_target="$(IFS=,; printf '%s' "${quoted_tables[*]}")"
    mysql_exec_db "$WP_DB_NAME" -e "OPTIMIZE TABLE ${optimize_target};"
    log "Optimize completed for ${#tables[@]} table(s)."
}

wp_popular_maintenance_bundle() {
    get_wp_context || return
    require_wp_tables options posts comments || return

    show_post_details_where "post_type='revision'" "Revisions selected for deletion"
    show_post_details_where "post_status IN ('trash', 'auto-draft')" "Trash/auto-draft posts selected for deletion"
    show_comment_details_where "c.comment_approved IN ('spam', 'trash')" "Spam/trash comments selected for deletion"

    maybe_backup_wp_db || return

    confirm "Run maintenance bundle (transients, revisions, trash/spam, orphans, optimize)?" || {
        log "Aborted."
        return
    }

    local options_table posts_table comments_table
    local posts_quoted comments_quoted postmeta_quoted commentmeta_quoted term_rel_quoted
    local deleted_transients deleted_revisions deleted_posts deleted_comments
    local deleted_postmeta=0 deleted_commentmeta=0 deleted_termrels=0

    options_table="$(quote_identifier "${WP_PREFIX}options")"
    posts_table="${WP_PREFIX}posts"
    comments_table="${WP_PREFIX}comments"
    posts_quoted="$(quote_identifier "$posts_table")"
    comments_quoted="$(quote_identifier "$comments_table")"

    deleted_transients="$(
        mysql_exec_db "$WP_DB_NAME" -N -s -e "
            DELETE FROM ${options_table}
            WHERE option_name REGEXP '^_(site_)?transient_';
            SELECT ROW_COUNT();
        " | tail -n1
    )"

    deleted_revisions="$(
        mysql_exec_db "$WP_DB_NAME" -N -s -e "
            DELETE FROM ${posts_quoted}
            WHERE post_type='revision';
            SELECT ROW_COUNT();
        " | tail -n1
    )"

    deleted_posts="$(
        mysql_exec_db "$WP_DB_NAME" -N -s -e "
            DELETE FROM ${posts_quoted}
            WHERE post_status IN ('trash', 'auto-draft');
            SELECT ROW_COUNT();
        " | tail -n1
    )"

    deleted_comments="$(
        mysql_exec_db "$WP_DB_NAME" -N -s -e "
            DELETE FROM ${comments_quoted}
            WHERE comment_approved IN ('spam', 'trash');
            SELECT ROW_COUNT();
        " | tail -n1
    )"

    if wp_table_exists "$WP_DB_NAME" "${WP_PREFIX}postmeta"; then
        postmeta_quoted="$(quote_identifier "${WP_PREFIX}postmeta")"
        deleted_postmeta="$(
            mysql_exec_db "$WP_DB_NAME" -N -s -e "
                DELETE pm FROM ${postmeta_quoted} pm
                LEFT JOIN ${posts_quoted} p ON p.ID = pm.post_id
                WHERE p.ID IS NULL;
                SELECT ROW_COUNT();
            " | tail -n1
        )"
    fi

    if wp_table_exists "$WP_DB_NAME" "${WP_PREFIX}commentmeta"; then
        commentmeta_quoted="$(quote_identifier "${WP_PREFIX}commentmeta")"
        deleted_commentmeta="$(
            mysql_exec_db "$WP_DB_NAME" -N -s -e "
                DELETE cm FROM ${commentmeta_quoted} cm
                LEFT JOIN ${comments_quoted} c ON c.comment_ID = cm.comment_id
                WHERE c.comment_ID IS NULL;
                SELECT ROW_COUNT();
            " | tail -n1
        )"
    fi

    if wp_table_exists "$WP_DB_NAME" "${WP_PREFIX}term_relationships"; then
        term_rel_quoted="$(quote_identifier "${WP_PREFIX}term_relationships")"
        deleted_termrels="$(
            mysql_exec_db "$WP_DB_NAME" -N -s -e "
                DELETE tr FROM ${term_rel_quoted} tr
                LEFT JOIN ${posts_quoted} p ON p.ID = tr.object_id
                WHERE p.ID IS NULL;
                SELECT ROW_COUNT();
            " | tail -n1
        )"
    fi

    local db_escaped prefix_escaped
    db_escaped="$(sql_escape_literal "$WP_DB_NAME")"
    prefix_escaped="$(sql_escape_literal "$WP_PREFIX")"
    local -a tables=()
    while IFS= read -r table_name; do
        [[ -n "$table_name" ]] && tables+=("$table_name")
    done < <(
        mysql_exec -N -s -e "
            SELECT TABLE_NAME
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA='${db_escaped}'
              AND TABLE_NAME LIKE CONCAT('${prefix_escaped}', '%')
            ORDER BY TABLE_NAME;
        "
    )

    if ((${#tables[@]} > 0)); then
        local -a quoted_tables=()
        for table_name in "${tables[@]}"; do
            quoted_tables+=("$(quote_identifier "$table_name")")
        done
        local optimize_target
        optimize_target="$(IFS=,; printf '%s' "${quoted_tables[*]}")"
        mysql_exec_db "$WP_DB_NAME" -e "OPTIMIZE TABLE ${optimize_target};"
    fi

    log "Maintenance bundle completed."
    log " - Transients removed          : ${deleted_transients:-0}"
    log " - Revisions removed           : ${deleted_revisions:-0}"
    log " - Trash/auto-draft posts      : ${deleted_posts:-0}"
    log " - Spam/trash comments         : ${deleted_comments:-0}"
    log " - Orphan postmeta             : ${deleted_postmeta:-0}"
    log " - Orphan commentmeta          : ${deleted_commentmeta:-0}"
    log " - Orphan term relationships   : ${deleted_termrels:-0}"
    log " - Tables optimized            : ${#tables[@]}"
}

show_menu() {
    clear 2>/dev/null || true
    print_header
    log ""
    log "${BLUE}1)${NC} Full domain migration (siteurl/home/guid/content/postmeta)"
    log "${BLUE}2)${NC} Search & replace in post_content"
    log "${BLUE}3)${NC} Remove query parameter in post_content links"
    log "${BLUE}4)${NC} Set siteurl + home only"
    log "${BLUE}5)${NC} Clear transients"
    log "${BLUE}6)${NC} Delete post revisions"
    log "${BLUE}7)${NC} Clean trash posts + spam comments"
    log "${BLUE}8)${NC} Cleanup orphan metadata/relationships"
    log "${BLUE}9)${NC} Optimize all WP tables"
    log "${BLUE}10)${NC} Popular maintenance bundle"
    log "${BLUE}11)${NC} Exit"
}

main() {
    local choice
    while true; do
        show_menu
        read -r -p "Choice [1-11]: " choice

        case "$choice" in
            1) wp_domain_migration ;;
            2) wp_replace_post_content ;;
            3) wp_remove_param_in_post_content ;;
            4) wp_set_siteurl_home ;;
            5) wp_clear_transients ;;
            6) wp_delete_revisions ;;
            7) wp_cleanup_trash_and_spam ;;
            8) wp_cleanup_orphans ;;
            9) wp_optimize_tables ;;
            10) wp_popular_maintenance_bundle ;;
            11)
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

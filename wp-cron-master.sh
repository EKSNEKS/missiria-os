#!/usr/bin/env bash

set -u
set -o pipefail

if [[ -t 1 ]]; then
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    RED=$'\033[0;31m'
    CYAN=$'\033[0;36m'
    BLUE=$'\033[0;34m'
    NC=$'\033[0m'
else
    GREEN=""
    YELLOW=""
    RED=""
    CYAN=""
    BLUE=""
    NC=""
fi

# Force WP-CLI to strictly use 256M max per process to prevent OOM kills.
export WP_CLI_PHP_ARGS="${WP_CLI_PHP_ARGS:--d memory_limit=256M}"

print_header() {
    printf '%b\n' "${CYAN}______  ____________________________________________________${NC}"
    printf '%b\n' "${CYAN}___   |/  /___  _/_  ___/_  ___/___  _/__  __ \\___  _/__    |${NC}"
    printf '%b\n' "${CYAN}__  /|_/ / __  / _____ \\_____ \\ __  / __  /_/ /__  / __  /| |${NC}"
    printf '%b\n' "${CYAN}_  /  / / __/ /  ____/ /____/ /__/ /  _  _, _/__/ /  _  ___ |${NC}"
    printf '%b\n' "${CYAN}/_/  /_/  /___/  /____/ /____/ /___/  /_/ |_| /___/  /_/  |_|${NC}"
    printf '%b\n' "${CYAN}                                                             v2${NC}"
    printf '%b\n' "${GREEN}WP-CRON MASTER${NC}"
}

log_info() {
    printf '%b\n' "${BLUE}$*${NC}"
}

log_ok() {
    printf '%b\n' "${GREEN}$*${NC}"
}

log_warn() {
    printf '%b\n' "${YELLOW}$*${NC}"
}

log_error() {
    printf '%b\n' "${RED}$*${NC}" >&2
}

usage() {
    cat <<'EOF'
Usage: ./wp-cron-master.sh [all|cron|updates]
  all      Run cron trigger + forced updates (default; updates skipped if WP-CLI is missing)
  cron     Run only wp-cron endpoint trigger
  updates  Run only forced WP-CLI updates
EOF
}

collect_nginx_files() {
    local -n out_files_ref="$1"
    shopt -s nullglob
    out_files_ref=(/etc/nginx/sites-enabled/*)
    shopt -u nullglob
    if ((${#out_files_ref[@]} == 0)); then
        log_error "No Nginx files found in /etc/nginx/sites-enabled/."
        return 1
    fi
}

collect_domains() {
    local -n out_domains_ref="$1"
    local -a nginx_files=()
    collect_nginx_files nginx_files || return 1

    mapfile -t out_domains_ref < <(
        awk '
            /^[[:space:]]*server_name[[:space:]]+/ {
                for (i = 2; i <= NF; i++) {
                    gsub(/;/, "", $i)
                    if ($i != "" && $i != "_" && $i !~ /^~/) {
                        print $i
                    }
                }
            }
        ' "${nginx_files[@]}" | sort -u
    )
}

collect_wp_site_paths() {
    local -n out_sites_ref="$1"
    local -a nginx_files=()
    collect_nginx_files nginx_files || return 1

    mapfile -t out_sites_ref < <(
        awk '
            /^[[:space:]]*root[[:space:]]+/ {
                path = $2
                gsub(/;|"/, "", path)
                gsub(/\047/, "", path)
                if (path ~ /^\//) {
                    print path
                }
            }
        ' "${nginx_files[@]}" | sort -u
    )
}

run_cron_trigger() {
    local -a domains=()
    local domain http_status ok_count=0 fail_count=0

    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl is required for cron trigger."
        return 1
    fi

    collect_domains domains || return 1
    if ((${#domains[@]} == 0)); then
        log_warn "No active domains found from Nginx server_name directives."
        return 0
    fi

    log_info "Triggering wp-cron.php on ${#domains[@]} domain(s)..."
    for domain in "${domains[@]}"; do
        log_warn "Pinging -> ${domain}"
        http_status="$(
            curl -s -o /dev/null -w "%{http_code}" -L -m 30 -A "Missiria-Cron-Bot" \
                "http://${domain}/wp-cron.php?doing_wp_cron"
        )"

        if [[ "$http_status" == "200" ]]; then
            log_ok "✓ Cron triggered successfully (HTTP 200)"
            ok_count=$((ok_count + 1))
        else
            log_error "✗ Failed or skipped (HTTP ${http_status}) - Ensure domain resolves to this VPS."
            fail_count=$((fail_count + 1))
        fi
        sleep 2
    done

    log_ok "Cron trigger complete: ${ok_count} success, ${fail_count} failed."
}

run_forced_updates() {
    local -a sites=()
    local site_path
    local updated_count=0 skipped_count=0 failed_count=0

    if ! command -v sudo >/dev/null 2>&1; then
        log_warn "sudo is not available. Skipping forced updates phase."
        return 0
    fi
    if ! command -v wp >/dev/null 2>&1; then
        log_warn "WP-CLI not found. Skipping forced updates phase."
        return 0
    fi

    collect_wp_site_paths sites || return 1
    if ((${#sites[@]} == 0)); then
        log_warn "No root paths found from Nginx configs."
        return 0
    fi

    log_info "Forcing immediate WP updates (Memory-Safe Mode) on ${#sites[@]} path(s)..."
    for site_path in "${sites[@]}"; do
        if [[ ! -d "$site_path" || ! -f "$site_path/wp-config.php" ]]; then
            skipped_count=$((skipped_count + 1))
            continue
        fi

        printf '\n'
        log_warn "Forcing updates for -> ${site_path}"

        if sudo -u www-data wp core update --path="$site_path" --quiet \
            && sudo -u www-data wp plugin update --all --path="$site_path" --quiet \
            && sudo -u www-data wp theme update --all --path="$site_path" --quiet \
            && sudo -u www-data wp language core update --path="$site_path" --quiet \
            && sudo -u www-data wp language plugin update --all --path="$site_path" --quiet \
            && sudo -u www-data wp language theme update --all --path="$site_path" --quiet; then
            log_ok "✓ Updates completed for ${site_path}"
            updated_count=$((updated_count + 1))
        else
            log_error "✗ Update failed for ${site_path}"
            failed_count=$((failed_count + 1))
        fi

        # Crucial for low RAM: pause between sites to reduce memory pressure.
        sleep 3
    done

    log_ok "Forced update complete: ${updated_count} updated, ${skipped_count} skipped, ${failed_count} failed."
}

main() {
    local mode="${1:-all}"
    print_header
    printf '\n'
    log_info "WP_CLI_PHP_ARGS=${WP_CLI_PHP_ARGS}"

    case "$mode" in
        all)
            run_cron_trigger
            printf '\n'
            run_forced_updates
            ;;
        cron)
            run_cron_trigger
            ;;
        updates)
            run_forced_updates
            ;;
        -h|--help|help)
            usage
            return 0
            ;;
        *)
            log_error "Invalid mode: $mode"
            usage
            return 1
            ;;
    esac
}

main "$@"

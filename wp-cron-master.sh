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
WP_CLI_BIN="${WP_CLI_BIN:-}"
WP_CLI_DOWNLOAD_URL="${WP_CLI_DOWNLOAD_URL:-https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar}"

declare -a WP_CLI_CMD=()

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
  all      Run cron trigger + forced updates (default; updates skipped only if WP-CLI cannot be resolved)
  cron     Run only wp-cron endpoint trigger
  updates  Run only forced WP-CLI updates (fails if updates cannot run)
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

collect_domain_root_pairs() {
    local -a nginx_files=()
    collect_nginx_files nginx_files || return 1

    awk '
        function clean(v) {
            gsub(/;|"/, "", v)
            gsub(/\047/, "", v)
            return v
        }
        function count_char(str, ch,    t) {
            t = str
            return gsub(ch, "", t)
        }
        function flush_block() {
            if (!in_server) {
                return
            }
            if (root != "" && domain_count > 0) {
                for (i = 1; i <= domain_count; i++) {
                    print root "|" domains[i] "|" FILENAME
                }
            }
            delete domains
            domain_count = 0
            root = ""
        }
        /^[[:space:]]*server[[:space:]]*\{/ {
            flush_block()
            in_server = 1
            depth = 1
            next
        }
        in_server {
            if ($0 ~ /^[[:space:]]*server_name[[:space:]]+/) {
                for (i = 2; i <= NF; i++) {
                    d = clean($i)
                    if (d != "" && d != "_" && d !~ /^~/) {
                        domains[++domain_count] = d
                    }
                }
            } else if ($0 ~ /^[[:space:]]*root[[:space:]]+/) {
                r = clean($2)
                if (r ~ /^\//) {
                    root = r
                }
            }

            depth += count_char($0, "{")
            depth -= count_char($0, "}")
            if (depth <= 0) {
                flush_block()
                in_server = 0
                depth = 0
            }
            next
        }
        END {
            flush_block()
        }
    ' "${nginx_files[@]}" | sort -u
}

resolve_wp_cli() {
    local tmp_wp_cli

    if [[ -n "$WP_CLI_BIN" && -x "$WP_CLI_BIN" ]]; then
        WP_CLI_CMD=("$WP_CLI_BIN")
        return 0
    fi

    if command -v wp >/dev/null 2>&1; then
        WP_CLI_CMD=("wp")
        return 0
    fi

    if ! command -v php >/dev/null 2>&1; then
        return 1
    fi

    tmp_wp_cli="/tmp/wp-cli.phar"
    if [[ ! -f "$tmp_wp_cli" ]]; then
        if ! command -v curl >/dev/null 2>&1; then
            return 1
        fi
        log_warn "WP-CLI not found in PATH. Downloading temporary wp-cli.phar..."
        if ! curl -fsSL "$WP_CLI_DOWNLOAD_URL" -o "$tmp_wp_cli"; then
            log_warn "Temporary WP-CLI download failed."
            return 1
        fi
    fi

    chmod +x "$tmp_wp_cli" 2>/dev/null || true
    if php "$tmp_wp_cli" --info >/dev/null 2>&1; then
        WP_CLI_CMD=("php" "$tmp_wp_cli")
        log_warn "Using temporary WP-CLI binary: $tmp_wp_cli"
        return 0
    fi

    return 1
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
    local strict_mode="${1:-0}"
    local -a pairs=()
    local -a roots=()
    local site_path domains pair root domain source wp_flag
    local updated_count=0 skipped_count=0 failed_count=0

    if ! command -v sudo >/dev/null 2>&1; then
        if [[ "$strict_mode" == "1" ]]; then
            log_error "sudo is required for forced updates."
            return 1
        fi
        log_warn "sudo is not available. Skipping forced updates phase."
        return 0
    fi

    if ! resolve_wp_cli; then
        if [[ "$strict_mode" == "1" ]]; then
            log_error "WP-CLI is required for updates and could not be resolved."
            return 1
        fi
        log_warn "WP-CLI not found. Skipping forced updates phase."
        return 0
    fi

    mapfile -t pairs < <(collect_domain_root_pairs)
    if ((${#pairs[@]} == 0)); then
        log_warn "No domain/root pairs found from Nginx configs."
        return 0
    fi

    log_info "Detected domains from Nginx (domain -> root -> wordpress):"
    for pair in "${pairs[@]}"; do
        IFS='|' read -r root domain source <<< "$pair"
        if [[ -f "$root/wp-config.php" ]]; then
            wp_flag="yes"
        else
            wp_flag="no"
        fi
        log_info " - ${domain} -> ${root} -> wp-config.php: ${wp_flag}"
    done

    mapfile -t roots < <(printf '%s\n' "${pairs[@]}" | cut -d'|' -f1 | sort -u)
    log_info "Forcing immediate WP updates (Memory-Safe Mode) on ${#roots[@]} unique site root(s)..."

    for site_path in "${roots[@]}"; do
        domains="$(
            printf '%s\n' "${pairs[@]}" \
                | awk -F'|' -v target_root="$site_path" '$1 == target_root {print $2}' \
                | sort -u | paste -sd ',' -
        )"
        domains="${domains:-unknown-domain}"

        if [[ ! -d "$site_path" || ! -f "$site_path/wp-config.php" ]]; then
            log_warn "Skipping non-WordPress root: ${site_path} (domains: ${domains})"
            skipped_count=$((skipped_count + 1))
            continue
        fi

        printf '\n'
        log_warn "Forcing updates for -> ${site_path}"
        log_info "Domains: ${domains}"

        if sudo -u www-data "${WP_CLI_CMD[@]}" core update --path="$site_path" --quiet \
            && sudo -u www-data "${WP_CLI_CMD[@]}" plugin update --all --path="$site_path" --quiet \
            && sudo -u www-data "${WP_CLI_CMD[@]}" theme update --all --path="$site_path" --quiet \
            && sudo -u www-data "${WP_CLI_CMD[@]}" language core update --path="$site_path" --quiet \
            && sudo -u www-data "${WP_CLI_CMD[@]}" language plugin update --all --path="$site_path" --quiet \
            && sudo -u www-data "${WP_CLI_CMD[@]}" language theme update --all --path="$site_path" --quiet; then
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
            run_forced_updates 0
            ;;
        cron)
            run_cron_trigger
            ;;
        updates)
            run_forced_updates 1
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

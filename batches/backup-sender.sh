#!/usr/bin/env bash
# backup-sender.sh — Ship local backup runs (produced by site-auto-backup.sh)
# to one or more remote servers via rsync/SSH.

set -u
set -o pipefail

# ── Configurable defaults (all overridable via environment) ───────────────────
BACKUP_BASE_DIR="${BACKUP_BASE_DIR:-/var/backups/missiria-auto}"
SENDER_CONFIG="${SENDER_CONFIG:-/etc/missiria/backup-sender.conf}"
SENDER_PASSWORDS="${SENDER_PASSWORDS:-/etc/missiria/backup-sender-passwords.conf}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-15}"
RSYNC_TIMEOUT="${RSYNC_TIMEOUT:-300}"
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-10}"
DRY_RUN="${DRY_RUN:-0}"
RSYNC_DELETE="${RSYNC_DELETE:-0}"

# ── Runtime state ─────────────────────────────────────────────────────────────
_SEND_MODE="latest"   # latest | all | run
_SEND_RUN=""          # used when _SEND_MODE=run
_TARGET_SERVER=""     # empty = all configured servers
_DO_LIST=0

declare -A _SERVER_HOST=()
declare -A _SERVER_PORT=()
declare -A _SERVER_USER=()
declare -A _SERVER_PATH=()
declare -A _SERVER_KEY=()
declare -a _SERVER_ORDER=()

declare -a SENT_OK=()
declare -a SENT_FAILED=()
declare -a SENT_SKIPPED=()

# ── Colors ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    RED=$'\033[0;31m'
    CYAN=$'\033[0;36m'
    BLUE=$'\033[0;34m'
    NC=$'\033[0m'
else
    GREEN="" YELLOW="" RED="" CYAN="" BLUE="" NC=""
fi

# ── Logging ───────────────────────────────────────────────────────────────────
log_info()  { printf '%b\n' "${BLUE}$*${NC}"; }
log_ok()    { printf '%b\n' "${GREEN}$*${NC}"; }
log_warn()  { printf '%b\n' "${YELLOW}$*${NC}"; }
log_error() { printf '%b\n' "${RED}$*${NC}" >&2; }

# ── Banner ────────────────────────────────────────────────────────────────────
print_header() {
    printf '%b\n' "${CYAN}______  ____________________________________________________${NC}"
    printf '%b\n' "${CYAN}___   |/  /___  _/_  ___/_  ___/___  _/__  __ \\___  _/__    |${NC}"
    printf '%b\n' "${CYAN}__  /|_/ / __  / _____ \\_____ \\ __  / __  /_/ /__  / __  /| |${NC}"
    printf '%b\n' "${CYAN}_  /  / / __/ /  ____/ /____/ /__/ /  _  _, _/__/ /  _  ___ |${NC}"
    printf '%b\n' "${CYAN}/_/  /_/  /___/  /____/ /____/ /___/  /_/ |_| /___/  /_/  |_|${NC}"
    printf '%b\n' "${CYAN}                                                   SENDER v1${NC}"
    printf '%b\n' "${GREEN}BACKUP SENDER — rsync to remote servers${NC}"
}

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Ship backup runs from ${BACKUP_BASE_DIR} to all configured remote servers.

Options:
  --latest            Send only the most recent backup run (default)
  --all               Send every backup run found in BACKUP_BASE_DIR
  --run STAMP         Send a specific run by timestamp (e.g. 20240501_030000)
  --server ALIAS      Send only to the named server (can repeat for multiple)
  --list              List available backup runs and configured servers, then exit
  --dry-run           Show what would be transferred without actually sending
  --help              Show this help

Environment variables (override defaults):
  BACKUP_BASE_DIR     Local backup root          (default: /var/backups/missiria-auto)
  SENDER_CONFIG       Server config file          (default: /etc/missiria/backup-sender.conf)
  SENDER_PASSWORDS    Passwords file              (default: /etc/missiria/backup-sender-passwords.conf)
  CONNECT_TIMEOUT     SSH connect timeout (s)     (default: 15)
  RSYNC_TIMEOUT       rsync I/O timeout (s)       (default: 300)
  MAX_RETRIES         Retry attempts per server   (default: 3)
  RETRY_DELAY         Seconds between retries     (default: 10)
  DRY_RUN             Set to 1 for dry run        (default: 0)
  RSYNC_DELETE        Set to 1 to --delete remote (default: 0)
  SSHPASS_<ALIAS>     Password for a server using password auth

Config file format  (${SENDER_CONFIG}):
  ALIAS|HOST|PORT|USER|REMOTE_PATH|SSH_KEY
  Use - as SSH_KEY to enable password authentication (requires sshpass).

Examples:
  $(basename "$0")                          # send latest run to all servers
  $(basename "$0") --server prod            # send latest run to 'prod' only
  $(basename "$0") --all --server staging   # send all runs to 'staging'
  $(basename "$0") --run 20240501_030000    # send a specific run
  $(basename "$0") --list                   # show runs and servers
  $(basename "$0") --dry-run                # preview without sending
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
parse_args() {
    local -a target_servers=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --latest)   _SEND_MODE="latest" ;;
            --all)      _SEND_MODE="all" ;;
            --run)
                [[ $# -lt 2 ]] && { log_error "--run requires a timestamp argument."; exit 1; }
                _SEND_MODE="run"
                _SEND_RUN="$2"
                shift
                ;;
            --server)
                [[ $# -lt 2 ]] && { log_error "--server requires an alias argument."; exit 1; }
                target_servers+=("$2")
                shift
                ;;
            --list)     _DO_LIST=1 ;;
            --dry-run)  DRY_RUN=1 ;;
            --help|-h)  usage; exit 0 ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
        shift
    done

    if ((${#target_servers[@]} > 0)); then
        _TARGET_SERVER="${target_servers[*]}"
    fi
}

# ── Dependency check ──────────────────────────────────────────────────────────
validate_deps() {
    local missing=0
    local dep

    for dep in rsync ssh; do
        if ! command -v "$dep" &>/dev/null; then
            log_error "Required dependency not found: ${dep}"
            missing=1
        fi
    done

    ((missing == 0))
}

# ── Config loading ────────────────────────────────────────────────────────────
load_server_configs() {
    if [[ ! -f "$SENDER_CONFIG" ]]; then
        log_error "Server config not found: ${SENDER_CONFIG}"
        log_warn "Create it with entries in format:  ALIAS|HOST|PORT|USER|REMOTE_PATH|SSH_KEY"
        log_warn "See backup-sender.md for setup instructions."
        return 1
    fi

    local line alias host port user remote_path ssh_key lineno=0

    while IFS= read -r line; do
        ((lineno++))
        line="${line%%#*}"         # strip inline comments
        line="${line#"${line%%[![:space:]]*}"}"  # ltrim
        line="${line%"${line##*[![:space:]]}"}"  # rtrim
        [[ -z "$line" ]] && continue

        IFS='|' read -r alias host port user remote_path ssh_key <<< "$line"

        alias="${alias#"${alias%%[![:space:]]*}"}"; alias="${alias%"${alias##*[![:space:]]}"}"
        host="${host#"${host%%[![:space:]]*}"}";   host="${host%"${host##*[![:space:]]}"}"

        if [[ -z "$alias" || -z "$host" || -z "$port" || -z "$user" || -z "$remote_path" || -z "$ssh_key" ]]; then
            log_warn "Config line ${lineno}: malformed entry — skipping. Expected: ALIAS|HOST|PORT|USER|REMOTE_PATH|SSH_KEY"
            continue
        fi

        if [[ ! "$port" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
            log_warn "Config line ${lineno}: invalid port '${port}' for alias '${alias}' — skipping."
            continue
        fi

        if [[ -n "${_SERVER_HOST[$alias]:-}" ]]; then
            log_warn "Config line ${lineno}: duplicate alias '${alias}' — skipping."
            continue
        fi

        _SERVER_HOST[$alias]="$host"
        _SERVER_PORT[$alias]="$port"
        _SERVER_USER[$alias]="$user"
        _SERVER_PATH[$alias]="${remote_path%/}"
        _SERVER_KEY[$alias]="$ssh_key"
        _SERVER_ORDER+=("$alias")

    done < "$SENDER_CONFIG"

    if ((${#_SERVER_ORDER[@]} == 0)); then
        log_error "No valid server entries found in ${SENDER_CONFIG}."
        return 1
    fi
}

# ── Password lookup ───────────────────────────────────────────────────────────
load_password() {
    local alias="$1"
    local env_key password

    # Normalize alias to uppercase, replacing non-alphanum with _
    env_key="SSHPASS_$(printf '%s' "$alias" | LC_ALL=C tr '[:lower:]' '[:upper:]' | LC_ALL=C sed 's/[^[:alnum:]]/_/g')"

    # 1. Try environment variable SSHPASS_<ALIAS>
    password="${!env_key:-}"
    if [[ -n "$password" ]]; then
        printf '%s' "$password"
        return 0
    fi

    # 2. Try passwords file
    if [[ -f "$SENDER_PASSWORDS" ]]; then
        local file_password
        file_password="$(
            LC_ALL=C grep -m1 "^${alias}[[:space:]]*=" "$SENDER_PASSWORDS" \
            | LC_ALL=C sed -nE "s/^[^=]+=[[:space:]]*['\"]?([^'\"]+)['\"]?[[:space:]]*$/\\1/p"
        )"
        if [[ -n "$file_password" ]]; then
            printf '%s' "$file_password"
            return 0
        fi
    fi

    return 1
}

# ── Backup run discovery ──────────────────────────────────────────────────────
get_latest_run() {
    local run_dir

    run_dir="$(
        find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null \
        | sort -z | tail -z -n1 \
        | tr -d '\0'
    )"

    if [[ -z "$run_dir" ]]; then
        return 1
    fi

    local run_name
    run_name="$(basename "$run_dir")"
    if [[ ! "$run_name" =~ ^[0-9]{8}_[0-9]{6}$ ]]; then
        return 1
    fi

    printf '%s\n' "$run_dir"
}

get_all_runs() {
    local -n _out_ref="$1"
    local run_dir run_name

    while IFS= read -r -d '' run_dir; do
        run_name="$(basename "$run_dir")"
        [[ "$run_name" =~ ^[0-9]{8}_[0-9]{6}$ ]] || continue
        _out_ref+=("$run_dir")
    done < <(
        find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null \
        | sort -z
    )
}

# ── List view ─────────────────────────────────────────────────────────────────
print_list() {
    local -a all_runs=()
    get_all_runs all_runs

    printf '\n'
    log_info "Configured servers:"
    if ((${#_SERVER_ORDER[@]} == 0)); then
        log_warn "  (none)"
    else
        local alias
        for alias in "${_SERVER_ORDER[@]}"; do
            local auth="key: ${_SERVER_KEY[$alias]}"
            [[ "${_SERVER_KEY[$alias]}" == "-" ]] && auth="password auth"
            log_info "  • ${alias} → ${_SERVER_USER[$alias]}@${_SERVER_HOST[$alias]}:${_SERVER_PORT[$alias]}  ${_SERVER_PATH[$alias]}  [${auth}]"
        done
    fi

    printf '\n'
    log_info "Available backup runs in ${BACKUP_BASE_DIR}:"
    if ((${#all_runs[@]} == 0)); then
        log_warn "  (none found)"
    else
        local run_dir
        for run_dir in "${all_runs[@]}"; do
            local size
            size="$(du -sh "$run_dir" 2>/dev/null | cut -f1)"
            log_ok "  • $(basename "$run_dir")  (${size:-?})"
        done
    fi
    printf '\n'
}

# ── Build shared SSH options array ────────────────────────────────────────────
build_ssh_opts() {
    local -n _opts_ref="$1"
    local alias="$2"
    local use_batch="${3:-yes}"   # yes | no

    local port="${_SERVER_PORT[$alias]}"
    local ssh_key="${_SERVER_KEY[$alias]}"

    _opts_ref=(
        -p "$port"
        -o "ConnectTimeout=${CONNECT_TIMEOUT}"
        -o "StrictHostKeyChecking=accept-new"
        -o "ServerAliveInterval=30"
        -o "ServerAliveCountMax=5"
    )

    if [[ "$use_batch" == "yes" ]]; then
        _opts_ref+=(-o "BatchMode=yes")
    fi

    if [[ "$ssh_key" != "-" ]]; then
        _opts_ref+=(-i "$ssh_key")
    fi
}

# ── Ensure remote directory exists ────────────────────────────────────────────
ensure_remote_dir() {
    local alias="$1"
    local remote_dir="$2"
    local use_sshpass="$3"
    local password="$4"

    local host="${_SERVER_HOST[$alias]}"
    local user="${_SERVER_USER[$alias]}"

    local -a ssh_opts=()
    if [[ "$use_sshpass" == "1" ]]; then
        build_ssh_opts ssh_opts "$alias" "no"
    else
        build_ssh_opts ssh_opts "$alias" "yes"
    fi

    local ssh_cmd_str
    ssh_cmd_str="$(printf '%q ' ssh "${ssh_opts[@]}" "${user}@${host}" "mkdir -p $(printf '%q' "$remote_dir")")"

    if [[ "$use_sshpass" == "1" ]]; then
        SSHPASS="$password" sshpass -e \
            ssh "${ssh_opts[@]}" "${user}@${host}" \
            "mkdir -p $(printf '%q' "$remote_dir")" &>/dev/null
    else
        ssh "${ssh_opts[@]}" "${user}@${host}" \
            "mkdir -p $(printf '%q' "$remote_dir")" &>/dev/null
    fi
}

# ── rsync a single run to a single server ─────────────────────────────────────
rsync_run() {
    local alias="$1"
    local run_dir="$2"
    local use_sshpass="$3"
    local password="$4"

    local host="${_SERVER_HOST[$alias]}"
    local user="${_SERVER_USER[$alias]}"
    local remote_path="${_SERVER_PATH[$alias]}"
    local run_stamp
    run_stamp="$(basename "$run_dir")"

    local -a ssh_opts=()
    if [[ "$use_sshpass" == "1" ]]; then
        build_ssh_opts ssh_opts "$alias" "no"
    else
        build_ssh_opts ssh_opts "$alias" "yes"
    fi

    local ssh_opt_str
    ssh_opt_str="ssh $(printf '%q ' "${ssh_opts[@]}")"

    local -a rsync_opts=(
        --archive
        --compress
        --human-readable
        --timeout="$RSYNC_TIMEOUT"
    )

    [[ -t 1 ]] && rsync_opts+=(--progress)
    [[ "$RSYNC_DELETE" == "1" ]] && rsync_opts+=(--delete)
    [[ "$DRY_RUN" == "1" ]] && rsync_opts+=(--dry-run)

    local dest="${user}@${host}:${remote_path}/${run_stamp}/"

    if [[ "$use_sshpass" == "1" ]]; then
        SSHPASS="$password" sshpass -e \
            rsync "${rsync_opts[@]}" -e "$ssh_opt_str" \
            "${run_dir}/" "$dest"
    else
        rsync "${rsync_opts[@]}" -e "$ssh_opt_str" \
            "${run_dir}/" "$dest"
    fi
}

# ── Send one run to one server (with retry) ───────────────────────────────────
send_run_to_server() {
    local alias="$1"
    local run_dir="$2"
    local run_stamp
    run_stamp="$(basename "$run_dir")"

    local host="${_SERVER_HOST[$alias]}"
    local user="${_SERVER_USER[$alias]}"
    local port="${_SERVER_PORT[$alias]}"
    local remote_path="${_SERVER_PATH[$alias]}"
    local ssh_key="${_SERVER_KEY[$alias]}"

    local use_sshpass=0
    local password=""

    # ── Auth validation ───────────────────────────────────────────────────────
    if [[ "$ssh_key" == "-" ]]; then
        use_sshpass=1
        if ! command -v sshpass &>/dev/null; then
            log_error "  ✗ [${alias}] sshpass not installed. Install it or switch to SSH key auth."
            return 1
        fi
        password="$(load_password "$alias" || true)"
        if [[ -z "$password" ]]; then
            log_error "  ✗ [${alias}] No password found. Set SSHPASS_${alias^^} env var or add '${alias}=password' to ${SENDER_PASSWORDS}"
            return 1
        fi
    else
        if [[ ! -f "$ssh_key" ]]; then
            log_error "  ✗ [${alias}] SSH key not found: ${ssh_key}"
            return 1
        fi
    fi

    log_warn ""
    log_warn "▶ Sending run ${run_stamp} → [${alias}] ${user}@${host}:${port}${remote_path}/${run_stamp}/"

    local size
    size="$(du -sh "$run_dir" 2>/dev/null | cut -f1)"
    log_info "  Local size: ${size:-unknown}"
    [[ "$DRY_RUN" == "1" ]] && log_warn "  [DRY RUN — no data will be transferred]"

    # ── Ensure remote directory exists ────────────────────────────────────────
    if [[ "$DRY_RUN" != "1" ]]; then
        if ! ensure_remote_dir "$alias" "${remote_path}/${run_stamp}" "$use_sshpass" "$password"; then
            log_error "  ✗ [${alias}] Could not create remote directory ${remote_path}/${run_stamp}"
            return 1
        fi
    fi

    # ── rsync with retry ──────────────────────────────────────────────────────
    local attempt=0
    local exit_code=0

    while ((attempt < MAX_RETRIES)); do
        ((attempt++))
        [[ "$attempt" -gt 1 ]] && log_warn "  Retry ${attempt}/${MAX_RETRIES} after ${RETRY_DELAY}s..."

        if rsync_run "$alias" "$run_dir" "$use_sshpass" "$password"; then
            return 0
        fi

        exit_code=$?

        if ((attempt < MAX_RETRIES)); then
            log_warn "  Transfer failed (exit ${exit_code}), waiting ${RETRY_DELAY}s before retry..."
            sleep "$RETRY_DELAY"
        fi
    done

    log_error "  ✗ [${alias}] Failed after ${MAX_RETRIES} attempt(s) (last exit: ${exit_code})"
    return 1
}

# ── Resolve which servers to send to ─────────────────────────────────────────
resolve_target_servers() {
    local -n _targets_ref="$1"

    if [[ -z "$_TARGET_SERVER" ]]; then
        _targets_ref=("${_SERVER_ORDER[@]}")
        return 0
    fi

    local alias
    for alias in $_TARGET_SERVER; do
        if [[ -z "${_SERVER_HOST[$alias]:-}" ]]; then
            log_error "Unknown server alias: '${alias}'. Check ${SENDER_CONFIG}"
            return 1
        fi
        _targets_ref+=("$alias")
    done
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"
    print_header
    printf '\n'

    validate_deps || exit 1
    load_server_configs || exit 1

    if ((_DO_LIST)); then
        print_list
        exit 0
    fi

    # ── Resolve runs to send ──────────────────────────────────────────────────
    local -a runs_to_send=()

    case "$_SEND_MODE" in
        latest)
            local latest_run
            latest_run="$(get_latest_run || true)"
            if [[ -z "$latest_run" ]]; then
                log_error "No backup runs found in ${BACKUP_BASE_DIR}."
                exit 1
            fi
            runs_to_send=("$latest_run")
            ;;
        all)
            get_all_runs runs_to_send
            if ((${#runs_to_send[@]} == 0)); then
                log_error "No backup runs found in ${BACKUP_BASE_DIR}."
                exit 1
            fi
            ;;
        run)
            local specific_run="${BACKUP_BASE_DIR%/}/${_SEND_RUN}"
            if [[ ! -d "$specific_run" ]]; then
                log_error "Backup run not found: ${specific_run}"
                exit 1
            fi
            runs_to_send=("$specific_run")
            ;;
    esac

    # ── Resolve target servers ────────────────────────────────────────────────
    local -a target_servers=()
    resolve_target_servers target_servers || exit 1

    log_info "Runs to send:  ${#runs_to_send[@]}"
    log_info "Target servers: ${#target_servers[@]} ($(IFS=', '; printf '%s' "${target_servers[*]}"))"
    [[ "$DRY_RUN" == "1" ]] && log_warn "DRY RUN MODE — no actual data will be transferred."

    # ── Send ──────────────────────────────────────────────────────────────────
    local global_start global_end total_time
    global_start=$(date +%s)

    local run_dir alias
    for run_dir in "${runs_to_send[@]}"; do
        for alias in "${target_servers[@]}"; do
            local start end duration
            start=$(date +%s)

            if send_run_to_server "$alias" "$run_dir"; then
                end=$(date +%s)
                duration=$((end - start))
                log_ok "  ✓ [${alias}] Sent $(basename "$run_dir") in ${duration}s"
                SENT_OK+=("$(basename "$run_dir") → ${alias}")
            else
                end=$(date +%s)
                duration=$((end - start))
                SENT_FAILED+=("$(basename "$run_dir") → ${alias}")
            fi
        done
    done

    # ── Summary ───────────────────────────────────────────────────────────────
    global_end=$(date +%s)
    total_time=$((global_end - global_start))

    printf '\n'
    log_ok "======================================================"
    log_ok " SEND COMPLETED IN ${total_time} SECONDS"
    log_ok "======================================================"

    if ((${#SENT_OK[@]} > 0)); then
        printf '\n'
        log_ok "Successfully sent (${#SENT_OK[@]}):"
        local item
        for item in "${SENT_OK[@]}"; do
            printf '  ✓ %s\n' "$item"
        done
    fi

    if ((${#SENT_FAILED[@]} > 0)); then
        printf '\n'
        log_error "Failed (${#SENT_FAILED[@]}):"
        local item
        for item in "${SENT_FAILED[@]}"; do
            printf '  ✗ %s\n' "$item"
        done
        exit 1
    fi
}

main "$@"

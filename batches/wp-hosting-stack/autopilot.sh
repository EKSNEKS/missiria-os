#!/usr/bin/env bash
# ============================================================
# AUTO-PILOT — WP-HOSTING-STACK LAUNCHER (paradiso)
# Phase 1: collect ALL inputs  →  Phase 2: execute
# Wraps the tested stack tools — no thousand-flag one-liners:
#   create-site.sh   provision tenant (user/db/pool/vhost/WP/TLS) + pull repo files
#   import-site.sh   clone a sister site's DATABASE into the tenant
#   deploy-wp        resync themes/plugins/mu-plugins from the repo checkout
# NEW  = blank site.   COPY = files from repo + DB cloned from a sister tenant.
# ============================================================
set -o pipefail
[[ $EUID -eq 0 ]] || { printf '\033[0;31m❌  run as root (or sudo).\033[0m\n'; exit 1; }

STACK="/root/wp-hosting-stack"
SITES_DIR="/etc/wp-hosting/sites"
DEFAULT_REPO="git@github.com:EKSNEKS/MIT-IX.git"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { printf '%b\n' "${GREEN}  ✅  $*${NC}"; }
warn() { printf '%b\n' "${YELLOW}  ⚠️   $*${NC}"; }
fail() { printf '%b\n' "${RED}  ❌  $*${NC}"; }
info() { printf '%b\n' "${CYAN}  ℹ️   $*${NC}"; }
ask()  { printf '%b' "  ${YELLOW}▶ $* ${NC}"; }
step() { echo ""; printf '%b\n' "${BLUE}════════════════════════════════════════════════════════════${NC}";
         printf '%b\n' "${BLUE}  $1${NC}"; printf '%b\n' "${BLUE}════════════════════════════════════════════════════════════${NC}"; echo ""; }

# ── intake vars ──────────────────────────────────────────────
MODE=""; DOMAIN=""; REPO="$DEFAULT_REPO"; BRANCH=""
SRC_DOMAIN=""; COPY_UPLOADS="n"; SKIP_SSL="n"

# list existing tenants (env basenames, minus .bak)
list_tenants() {
    find "$SITES_DIR" -maxdepth 1 -name '*.env' ! -name '*.bak*' 2>/dev/null \
        | sed 's#.*/##; s/\.env$//' | sort
}

# ============================================================
# PHASE 1 — INTAKE
# ============================================================
intake_mode() {
    echo ""
    printf '%b\n' "  ${BOLD}[N]${NC}  NEW  — blank WordPress from the repo"
    printf '%b\n' "  ${BOLD}[C]${NC}  COPY — repo files + DATABASE cloned from a sister site"
    echo ""
    while true; do
        ask "Choice [N/C]:"; read -r c
        case "${c,,}" in n|new) MODE=new; break;; c|copy) MODE=copy; break;; *) warn "N or C.";; esac
    done
}

intake_domain() {
    echo ""; printf '%b\n' "  ${CYAN}── TARGET DOMAIN ─────────────────────────${NC}"
    while [[ -z "$DOMAIN" ]]; do
        ask "New domain (e.g. iptv-x.com):"; read -r DOMAIN
        DOMAIN="${DOMAIN#http://}"; DOMAIN="${DOMAIN#https://}"
        DOMAIN="${DOMAIN#www.}"; DOMAIN="${DOMAIN%%/*}"; DOMAIN="${DOMAIN// /}"; DOMAIN="${DOMAIN,,}"
        [[ -z "$DOMAIN" ]] && warn "Domain required."
    done
    if [[ -f "$SITES_DIR/$DOMAIN.env" ]]; then
        warn "Tenant $DOMAIN already exists — create-site re-run will repair/update it (idempotent)."
    fi
}

intake_repo() {
    echo ""; printf '%b\n' "  ${CYAN}── CLIENT REPO (files) ───────────────────${NC}"
    info "Repo whose themes/plugins/mu-plugins become the site files."
    ask "Repo URL [$DEFAULT_REPO]:"; read -r r
    REPO="${r:-$DEFAULT_REPO}"
    ask "Branch (blank = default):"; read -r BRANCH
    [[ -n "$REPO" ]] && info "Files from: $REPO ${BRANCH:+(branch $BRANCH)}" || info "No repo — blank wp-content."
}

intake_copy_source() {
    echo ""; printf '%b\n' "  ${CYAN}── SOURCE SITE (DB clone) ────────────────${NC}"
    local -a t=(); while IFS= read -r x; do [[ "$x" != "$DOMAIN" ]] && t+=("$x"); done < <(list_tenants)
    if ((${#t[@]})); then
        info "Existing tenants:"; for i in "${!t[@]}"; do printf '%b\n' "    ${BLUE}[$((i+1))]${NC} ${t[$i]}"; done; echo ""
        ask "Source tenant number (or blank to type):"; read -r idx
        [[ "$idx" =~ ^[0-9]+$ ]] && ((idx>=1 && idx<=${#t[@]})) && SRC_DOMAIN="${t[$((idx-1))]}"
    fi
    while [[ -z "$SRC_DOMAIN" ]]; do
        ask "Source tenant domain (clone its DB):"; read -r SRC_DOMAIN
        [[ -f "$SITES_DIR/$SRC_DOMAIN.env" ]] || { warn "No tenant $SRC_DOMAIN."; SRC_DOMAIN=""; }
    done
    info "DB source: $SRC_DOMAIN  →  import-site rewrites its URL to $DOMAIN"
    echo ""
    ask "Also copy uploads/ media from $SRC_DOMAIN? [y/N]:"; read -r COPY_UPLOADS; COPY_UPLOADS="${COPY_UPLOADS:-n}"
}

intake_ssl() {
    echo ""; printf '%b\n' "  ${CYAN}── SSL ───────────────────────────────────${NC}"
    info "Cert needs Cloudflare origin → this server (109.199.102.152) first."
    ask "Skip Certbot for now? (issue later) [y/N]:"; read -r SKIP_SSL; SKIP_SSL="${SKIP_SSL:-n}"
}

edit_loop() {
    while true; do
        echo ""; printf '%b\n' "  ${CYAN}── EDIT ──────────────────────────────────${NC}"
        printf '%b\n' "  ${BOLD}[1]${NC} Domain     : $DOMAIN"
        printf '%b\n' "  ${BOLD}[2]${NC} Repo       : ${REPO:-(none)} ${BRANCH:+[$BRANCH]}"
        printf '%b\n' "  ${BOLD}[3]${NC} Skip SSL   : $SKIP_SSL"
        if [[ "$MODE" == copy ]]; then
            printf '%b\n' "  ${BOLD}[4]${NC} Source DB  : $SRC_DOMAIN"
            printf '%b\n' "  ${BOLD}[5]${NC} Copy media : $COPY_UPLOADS"
        fi
        printf '%b\n' "  ${BOLD}[0]${NC} Done"
        ask "Edit which? [0]:"; read -r e
        case "$e" in
            0|"") break;;
            1) DOMAIN=""; intake_domain;;
            2) intake_repo;;
            3) ask "Skip SSL? [y/N]:"; read -r SKIP_SSL; SKIP_SSL="${SKIP_SSL:-n}";;
            4) [[ "$MODE" == copy ]] && { SRC_DOMAIN=""; intake_copy_source; } || warn "COPY only.";;
            5) [[ "$MODE" == copy ]] && { ask "Copy media? [y/N]:"; read -r COPY_UPLOADS; COPY_UPLOADS="${COPY_UPLOADS:-n}"; } || warn "COPY only.";;
            *) warn "Invalid.";;
        esac
    done
}

summary() {
    step "SUMMARY — REVIEW BEFORE LAUNCH"
    printf '    Mode        : %b%s%b\n' "$BOLD" "${MODE^^}" "$NC"
    printf '    Domain      : %s\n' "$DOMAIN"
    printf '    Files (repo): %s %s\n' "${REPO:-(blank)}" "${BRANCH:+[$BRANCH]}"
    [[ "$MODE" == copy ]] && { printf '    DB clone    : %s  →  %s\n' "$SRC_DOMAIN" "$DOMAIN"
                               printf '    Copy media  : %s\n' "$COPY_UPLOADS"; }
    printf '    Certbot SSL : %s\n' "$([[ "${SKIP_SSL,,}" == y ]] && echo SKIP || echo YES)"
    echo ""
    printf '%b\n' "  ${CYAN}Plan:${NC}"
    printf '%b\n' "  ${BLUE}1${NC} create-site.sh $DOMAIN $([[ "${SKIP_SSL,,}" == y ]] && echo --no-ssl) ${REPO:+--repo $REPO}"
    [[ "$MODE" == copy ]] && printf '%b\n' "  ${BLUE}2${NC} import-site.sh $DOMAIN --from-local $SRC_DOMAIN"
    [[ "$MODE" == copy && "${COPY_UPLOADS,,}" == y ]] && printf '%b\n' "  ${BLUE}3${NC} rsync uploads $SRC_DOMAIN → $DOMAIN"
    printf '%b\n' "  ${BLUE}*${NC} deploy-wp $DOMAIN  +  homepage audit"
    echo ""
}

# ============================================================
# PHASE 2 — EXECUTION
# ============================================================
exec_all() {
    step "PHASE 2 — EXECUTION → $DOMAIN"

    # 1. provision + repo files
    local cargs=("$DOMAIN"); [[ "${SKIP_SSL,,}" == y ]] && cargs+=(--no-ssl)
    [[ -n "$REPO" ]] && cargs+=(--repo "$REPO"); [[ -n "$BRANCH" ]] && cargs+=(--repo-branch "$BRANCH")
    info "create-site.sh ${cargs[*]}"
    "$STACK/create-site.sh" "${cargs[@]}" || { fail "create-site failed"; return 1; }
    ok "tenant provisioned + repo files synced"

    # 2. DB clone (COPY)
    if [[ "$MODE" == copy ]]; then
        info "import-site.sh $DOMAIN --from-local $SRC_DOMAIN"
        "$STACK/import-site.sh" "$DOMAIN" --from-local "$SRC_DOMAIN" || { fail "import-site failed"; return 1; }
        ok "database cloned from $SRC_DOMAIN"
    fi

    # 3. uploads (optional)
    if [[ "$MODE" == copy && "${COPY_UPLOADS,,}" == y ]]; then
        # shellcheck disable=SC1090
        local S_DOC T_DOC T_USER
        S_DOC="$(grep -E '^DOCROOT=' "$SITES_DIR/$SRC_DOMAIN.env" | cut -d'"' -f2)"
        T_DOC="$(grep -E '^DOCROOT=' "$SITES_DIR/$DOMAIN.env" | cut -d'"' -f2)"
        T_USER="$(grep -E '^SYSUSER=' "$SITES_DIR/$DOMAIN.env" | cut -d'"' -f2)"
        if [[ -d "$S_DOC/wp-content/uploads" ]]; then
            info "rsync uploads → $T_DOC"
            install -d -o "$T_USER" -g "$T_USER" "$T_DOC/wp-content/uploads"
            rsync -a "$S_DOC/wp-content/uploads/" "$T_DOC/wp-content/uploads/"
            chown -R "$T_USER":"$T_USER" "$T_DOC/wp-content/uploads"
            ok "uploads copied"
        else
            warn "source has no uploads/ — skipped"
        fi
    fi

    # 4. resync repo over imported DB
    info "deploy-wp $DOMAIN"
    deploy-wp "$DOMAIN" >/dev/null 2>&1 && ok "repo resynced" || warn "deploy-wp reported issues (check manually)"

    # 5. audit
    step "AUDIT"
    local code
    code="$(curl -sk -o /dev/null -w '%{http_code}' --resolve "www.$DOMAIN:443:127.0.0.1" "https://www.$DOMAIN/" 2>/dev/null || true)"
    if [[ "$code" == 200 ]]; then ok "https://www.$DOMAIN/ → 200"
    else
        code="$(curl -s -o /dev/null -w '%{http_code}' --resolve "www.$DOMAIN:80:127.0.0.1" "http://www.$DOMAIN/" 2>/dev/null || true)"
        [[ "$code" =~ ^(200|301|302)$ ]] && ok "http origin → $code (no-SSL tenant; issue cert after DNS cutover)" || warn "homepage → $code"
    fi
    echo ""
    info "Creds: $SITES_DIR/$DOMAIN.env"
    [[ "${SKIP_SSL,,}" == y ]] && info "SSL later: point Cloudflare origin → 109.199.102.152, then: $STACK/create-site.sh $DOMAIN"
    printf '%b\n' "${GREEN}${BOLD}  🎉  Auto-pilot complete → $DOMAIN${NC}"; echo ""
}

# ============================================================
main() {
    clear
    printf '%b\n' "${CYAN}${BOLD}  ╔════════════════════════════════════════════════╗${NC}"
    printf '%b\n' "${CYAN}${BOLD}  ║  AUTO-PILOT — wp-hosting-stack launcher        ║${NC}"
    printf '%b\n' "${CYAN}${BOLD}  ║  PHASE 1 — answer questions. Exec after.       ║${NC}"
    printf '%b\n' "${CYAN}${BOLD}  ╚════════════════════════════════════════════════╝${NC}"

    intake_mode
    intake_domain
    intake_repo
    [[ "$MODE" == copy ]] && intake_copy_source
    intake_ssl

    while true; do
        summary
        printf '%b\n' "  ${BOLD}[E]${NC}dit   ${BOLD}[L]${NC}aunch   ${BOLD}[Q]${NC}uit"
        ask "Choice [E/L/Q]:"; read -r ch
        case "${ch,,}" in e|edit) edit_loop;; l|launch) break;; q|quit) echo "  Cancelled."; exit 0;; *) warn "E/L/Q.";; esac
    done

    exec_all
}
main "$@"

#!/bin/bash

# ── URL Checker — full-site broken link scanner ───────────────────────────────
# 1. Selects active nginx WordPress site
# 2. Crawls via sitemap.xml (all URLs) + extracts hrefs from each page
# 3. Reports every internal URL returning 404 + which page links to it

set -uo pipefail

if [ "$EUID" -ne 0 ]; then echo "❌ Run as root." >&2; exit 1; fi

# ── Colors ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
confirm() {
    local ans
    read -rp "$(printf '%b' "${YELLOW}${1:-Proceed?} [y/N]: ${NC}")" ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

header() {
    echo ""
    printf '%b\n' "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    printf '%b\n' "${CYAN}║        🔍  URL CHECKER — FULL SITE BROKEN LINKS      ║${NC}"
    printf '%b\n' "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ── Fetch URL via nginx:8080 directly (bypass Varnish cache) ──────────────────
# Returns: STATUS_CODE\tBODY
fetch_backend() {
    local path="$1" domain="$2"
    curl -s --max-time 10 \
        -H "Host: www.${domain}" \
        -w "\n__STATUS__%{http_code}" \
        "http://127.0.0.1:8080${path}" 2>/dev/null
}

check_status() {
    local path="$1" domain="$2"
    curl -s -o /dev/null --max-time 10 \
        -H "Host: www.${domain}" \
        -w "%{http_code}" \
        "http://127.0.0.1:8080${path}" 2>/dev/null
}

# ── Extract all href / src paths from HTML (internal paths only) ─────────────
# External links (different domain, tel:, mailto:, wa.me, etc.) are excluded.
extract_links() {
    local html="$1" domain="$2"
    echo "$html" | grep -oE \
        "(href|src|action)=['\"]((https?://(www\.)?${domain//./\\.})?/[^'\"#?][^'\"]*)['\"]" \
        | grep -oE "((https?://(www\.)?${domain//./\\.})?/[^'\"#?][^'\"]*)" \
        | sed "s|https\?://\(www\.\)\?${domain//./\\.}||" \
        | grep -E "^/" \
        | grep -vE "^//[^/]" \
        | grep -vE "\.(css|js|png|jpg|jpeg|gif|svg|ico|webp|woff|woff2|ttf|eot|pdf|zip|xml|txt|mp4|m4v|map)(\?.*)?$" \
        | grep -vE "^/(wp-content|wp-includes|wp-admin|webmail)" \
        | sort -u
}

# ── Classify a broken path — returns hint string if special ───────────────────
path_hint() {
    local path="$1"
    # Digit-only path = phone number stored without scheme (e.g. should be https://wa.me/XXXXXX)
    if [[ "$path" =~ ^/([0-9]{7,15})$ ]]; then
        echo "PHONE:${BASH_REMATCH[1]}"
    else
        echo ""
    fi
}

# ── Parse sitemap (index + sub-sitemaps) → list of paths ─────────────────────
parse_sitemap() {
    local domain="$1"
    local all_paths=()

    # Try sitemap_index.xml first, then sitemap.xml
    for sitemap_path in "/sitemap_index.xml" "/sitemap.xml"; do
        local content
        content=$(curl -s --max-time 15 \
            -H "Host: www.${domain}" \
            "http://127.0.0.1:8080${sitemap_path}" 2>/dev/null)
        [ -z "$content" ] && continue
        echo "$content" | grep -q "xml" || continue

        # Sub-sitemap index?
        if echo "$content" | grep -q "<sitemapindex"; then
            local sub_urls
            sub_urls=$(echo "$content" | grep -oE "<loc>[^<]+</loc>" | sed 's|<loc>||;s|</loc>||' \
                | sed "s|https\?://\(www\.\)\?${domain//./\\.}||")
            while IFS= read -r sub; do
                [ -z "$sub" ] && continue
                local sub_content
                sub_content=$(curl -s --max-time 15 \
                    -H "Host: www.${domain}" \
                    "http://127.0.0.1:8080${sub}" 2>/dev/null)
                while IFS= read -r loc; do
                    loc=$(echo "$loc" | sed "s|https\?://\(www\.\)\?${domain//./\\.}||")
                    [[ "$loc" == /* ]] && all_paths+=("$loc")
                done < <(echo "$sub_content" | grep -oE "<loc>[^<]+</loc>" | sed 's|<loc>||;s|</loc>||')
            done <<< "$sub_urls"
            break
        else
            # Simple sitemap.xml
            while IFS= read -r loc; do
                loc=$(echo "$loc" | sed "s|https\?://\(www\.\)\?${domain//./\\.}||")
                [[ "$loc" == /* ]] && all_paths+=("$loc")
            done < <(echo "$content" | grep -oE "<loc>[^<]+</loc>" | sed 's|<loc>||;s|</loc>||')
            break
        fi
    done

    printf '%s\n' "${all_paths[@]}" | sort -u
}

# ── Build site list from active nginx configs ─────────────────────────────────
get_sites() {
    local sites=()
    for cfg in /etc/nginx/sites-enabled/*; do
        local domain root
        domain=$(basename "$cfg")
        [[ "$domain" =~ ^(00-catch-all|it-dashboard\.conf|leader|missiria-drive\.) ]] && continue
        root=$(grep -m1 "^\s*root " "$cfg" 2>/dev/null | awk '{print $2}' | tr -d ';')
        [ -z "$root" ] || [ ! -f "${root}/wp-config.php" ] && continue
        sites+=("$domain|$root")
    done
    printf '%s\n' "${sites[@]}"
}

# ── MAIN ──────────────────────────────────────────────────────────────────────
header

mapfile -t SITES < <(get_sites)
if [ ${#SITES[@]} -eq 0 ]; then
    echo -e "${RED}No WordPress sites found.${NC}"; exit 1
fi

echo -e "${BOLD}Active WordPress sites:${NC}\n"
for i in "${!SITES[@]}"; do
    printf "  ${GREEN}[%2d]${NC}  %s\n" "$((i+1))" "${SITES[$i]%%|*}"
done

echo ""
read -rp "$(printf '%b' "${YELLOW}Select site number (0 = exit): ${NC}")" CHOICE

[[ "$CHOICE" == "0" || -z "$CHOICE" ]] && { echo "Cancelled."; exit 0; }
if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "${#SITES[@]}" ]; then
    echo -e "${RED}Invalid selection.${NC}"; exit 1
fi

SELECTED="${SITES[$((CHOICE-1))]}"
DOMAIN="${SELECTED%%|*}"
ROOT="${SELECTED##*|}"

echo ""
echo -e "${CYAN}Site   :${NC} ${BOLD}www.${DOMAIN}${NC}"
echo -e "${CYAN}Docroot:${NC} ${ROOT}"
echo ""

# ── Scan mode ────────────────────────────────────────────────────────────────
echo -e "${BOLD}Scan mode:${NC}"
echo "  [1]  Sitemap only   — check all URLs in sitemap.xml (fast)"
echo "  [2]  Full crawl     — sitemap + follow every internal link found (thorough)"
echo ""
read -rp "$(printf '%b' "${YELLOW}Mode [1/2]: ${NC}")" MODE
[[ "$MODE" != "1" && "$MODE" != "2" ]] && MODE="1"

echo ""
confirm "Start scan of www.${DOMAIN} (mode: ${MODE})?" || { echo "Cancelled."; exit 0; }

echo ""
echo -e "${CYAN}Step 1/3 — Loading sitemap...${NC}"

mapfile -t SITEMAP_PATHS < <(parse_sitemap "$DOMAIN")
SITEMAP_COUNT=${#SITEMAP_PATHS[@]}

if [ "$SITEMAP_COUNT" -eq 0 ]; then
    echo -e "${YELLOW}No sitemap found — falling back to homepage crawl only.${NC}"
    SITEMAP_PATHS=("/")
    SITEMAP_COUNT=1
else
    echo -e "  Sitemap URLs: ${BOLD}${SITEMAP_COUNT}${NC}"
fi

# ── Collect all URLs to check ─────────────────────────────────────────────────
QUEUE_FILE=$(mktemp /tmp/url-checker-queue-XXXXXX)
SEEN_FILE=$(mktemp /tmp/url-checker-seen-XXXXXX)
BROKEN_FILE=$(mktemp /tmp/url-checker-broken-XXXXXX)

printf '%s\n' "${SITEMAP_PATHS[@]}" >> "$QUEUE_FILE"
printf '%s\n' "${SITEMAP_PATHS[@]}" >> "$SEEN_FILE"

if [ "$MODE" == "2" ]; then
    echo ""
    echo -e "${CYAN}Step 2/3 — Crawling pages to extract all internal links...${NC}"

    CRAWLED=0
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        ((CRAWLED++))
        printf '\r  Crawled: %d / %d  |  URLs queued: %d' \
            "$CRAWLED" "$SITEMAP_COUNT" "$(wc -l < "$QUEUE_FILE")"

        local_html=$(fetch_backend "$path" "$DOMAIN")
        while IFS= read -r link; do
            [ -z "$link" ] && continue
            if ! grep -qxF "$link" "$SEEN_FILE" 2>/dev/null; then
                echo "$link" >> "$QUEUE_FILE"
                echo "$link" >> "$SEEN_FILE"
            fi
        done < <(extract_links "$local_html" "$DOMAIN")
    done < <(printf '%s\n' "${SITEMAP_PATHS[@]}")

    printf '\r%*s\r' 70 ''
    echo -e "  Total unique URLs to check: ${BOLD}$(wc -l < "$QUEUE_FILE")${NC}"
fi

# ── Extract DB credentials once (from wp-config.php) ─────────────────────────
DB_NAME=$(grep "DB_NAME"     "${ROOT}/wp-config.php" | grep -o "'[^']*'" | tail -1 | tr -d "'")
DB_USER=$(grep "DB_USER"     "${ROOT}/wp-config.php" | grep -o "'[^']*'" | tail -1 | tr -d "'")
DB_PASS=$(grep "DB_PASSWORD" "${ROOT}/wp-config.php" | grep -o "'[^']*'" | tail -1 | tr -d "'")
DB_HOST=$(grep "DB_HOST"     "${ROOT}/wp-config.php" | grep -o "'[^']*'" | tail -1 | tr -d "'")
PREFIX=$(grep  "table_prefix" "${ROOT}/wp-config.php" | grep -o "'[^']*'" | tr -d "'")

# ── Check each URL ────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}Step 3/3 — Checking HTTP status of all URLs...${NC}"
echo ""

TOTAL_URLS=$(sort -u "$QUEUE_FILE" | grep -c "." || true)
CHECKED=0
BROKEN_COUNT=0

while IFS= read -r path; do
    [ -z "$path" ] && continue
    ((CHECKED++))
    printf '\r  Checked: %d / %d  |  Broken: %d' "$CHECKED" "$TOTAL_URLS" "$BROKEN_COUNT"

    STATUS=$(check_status "$path" "$DOMAIN")

    if [[ "$STATUS" == "404" || "$STATUS" == "000" || "$STATUS" == "410" ]]; then
        ((BROKEN_COUNT++))
        # Find which published posts link to this broken URL; return ID:slug pairs
        FULL_URL="https://www.${DOMAIN}${path}"
        SAFE=$(printf '%s' "$path" | sed "s/'/\\\\'/g; s/%/%%/g")
        # Search for the path only inside href/src/action attributes to avoid
        # false positives (e.g. wa.me/212661377106 matching search for /212661377106)
        REFERRER_SLUGS=$(mysql -u"$DB_USER" -p"$DB_PASS" -h"$DB_HOST" "$DB_NAME" -se \
            "SELECT GROUP_CONCAT(DISTINCT CONCAT(ID, ':', post_name) ORDER BY ID SEPARATOR ' | ')
             FROM ${PREFIX}posts
             WHERE post_status='publish'
               AND (post_content LIKE '%href=\"${SAFE}\"%'
                    OR post_content LIKE \"%href='${SAFE}'%\"
                    OR post_content LIKE '%href=\"${FULL_URL//\//\\/}\"%'
                    OR post_content LIKE \"%href='${FULL_URL//\//\\/}'%\")
             LIMIT 1;" 2>/dev/null)
        printf '%s\t%s\t%s\n' "$path" "$STATUS" "${REFERRER_SLUGS:-not_found_in_db}" >> "$BROKEN_FILE"
    fi
done < <(sort -u "$QUEUE_FILE")

printf '\r%*s\r' 70 ''

# ── Report ────────────────────────────────────────────────────────────────────
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                    SCAN COMPLETE                     ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Site    : ${BOLD}www.${DOMAIN}${NC}"
echo -e "  Checked : ${BOLD}${CHECKED}${NC} unique URLs"
echo -e "  Broken  : ${RED}${BOLD}${BROKEN_COUNT}${NC}"
echo ""

if [ "$BROKEN_COUNT" -gt 0 ]; then
    echo -e "${RED}${BOLD}Broken URLs:${NC}\n"
    printf "  ${BOLD}%-55s  %-6s  %s${NC}\n" "BROKEN URL PATH" "STATUS" "FOUND IN (id:slug  →  /wp-admin/post.php?post=ID&action=edit)"
    printf '  %s\n' "$(printf '%.0s─' {1..110})"

    while IFS=$'\t' read -r path status post_refs; do
        STATUS_COLOR="$YELLOW"
        [[ "$status" == "404" ]] && STATUS_COLOR="$RED"
        [[ "$status" == "000" ]] && STATUS_COLOR="$RED"
        # Build admin edit hints from "42:slug | 55:other" format
        EDIT_HINTS=""
        if [[ "$post_refs" != "not_found_in_db" && -n "$post_refs" ]]; then
            while IFS='|' read -ra PAIRS; do
                for pair in "${PAIRS[@]}"; do
                    pair="${pair// /}"
                    id="${pair%%:*}"
                    slug="${pair##*:}"
                    [[ -n "$id" && "$id" =~ ^[0-9]+$ ]] && \
                        EDIT_HINTS+="${id}:${slug} → /wp-admin/post.php?post=${id}&action=edit  "
                done
            done <<< "$post_refs"
        else
            EDIT_HINTS="$post_refs"
        fi
        printf "  ${RED}%-55s${NC}  ${STATUS_COLOR}%-6s${NC}  ${BLUE}%s${NC}\n" \
            "$path" "$status" "$EDIT_HINTS"
        # Warn when path is a bare phone number — stored without scheme in post content
        hint=$(path_hint "$path")
        if [[ "$hint" == PHONE:* ]]; then
            digits="${hint#PHONE:}"
            printf "  ${YELLOW}  ↳ External link stored as internal path. Fix in post content:${NC}\n"
            printf "  ${YELLOW}    href=\"/%-*s${NC}${YELLOW}\" → href=\"https://wa.me/%s\"${NC}\n" \
                "${#digits}" "$digits" "$digits"
        fi
    done < "$BROKEN_FILE"

    echo ""

    REPORT="/var/www/MISSIRIA/url-checker-report-${DOMAIN}-$(date +%Y%m%d-%H%M%S).txt"
    {
        echo "URL Checker Report"
        echo "Site    : www.${DOMAIN}"
        echo "Date    : $(date)"
        echo "Checked : ${CHECKED} URLs"
        echo "Broken  : ${BROKEN_COUNT}"
        echo ""
        printf '%-80s\t%-6s\t%-30s\t%s\n' "BROKEN_URL" "STATUS" "POST_ID:SLUG" "ADMIN_EDIT_URL"
        while IFS=$'\t' read -r path status post_refs; do
            file_hint=""
            fh=$(path_hint "$path")
            if [[ "$fh" == PHONE:* ]]; then
                file_hint="  ⚠ Phone/WA number stored as internal path — fix: href=\"https://wa.me/${fh#PHONE:}\""
            fi
            if [[ "$post_refs" != "not_found_in_db" && -n "$post_refs" ]]; then
                while IFS='|' read -ra PAIRS; do
                    for pair in "${PAIRS[@]}"; do
                        pair="${pair// /}"
                        id="${pair%%:*}"
                        slug="${pair##*:}"
                        if [[ -n "$id" && "$id" =~ ^[0-9]+$ ]]; then
                            printf '%-80s\t%-6s\t%-30s\t%s%s\n' \
                                "$path" "$status" "${id}:${slug}" \
                                "https://www.${DOMAIN}/wp-admin/post.php?post=${id}&action=edit" \
                                "$file_hint"
                        fi
                    done
                done <<< "$post_refs"
            else
                printf '%-80s\t%-6s\t%-30s\t%s\n' "$path" "$status" "not_found_in_db" "$file_hint"
            fi
        done < "$BROKEN_FILE"
    } > "$REPORT"

    echo -e "${GREEN}Full report saved:${NC} ${REPORT}"
    echo ""
    echo -e "${YELLOW}Fix:${NC} For each broken URL, update post_content in the listed Post IDs."
    echo -e "       Use WP admin editor or direct DB UPDATE on ${DB_NAME:-<db>}.${PREFIX:-<prefix>}posts."
else
    echo -e "  ${GREEN}✅ No broken links found — site is clean.${NC}"
fi

rm -f "$QUEUE_FILE" "$SEEN_FILE" "$BROKEN_FILE"
echo ""

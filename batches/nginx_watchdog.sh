#!/bin/bash

# --- CONFIGURATION ---
EMAIL_DEST="missiria@gmail.com"
NGINX_PATH="/etc/nginx/sites-enabled"
MIN_WORDS=500
LOG_FILE="/var/log/nginx_monitor.log"

# 🆕 THE WHITELIST: Domains allowed to have low word counts (Coming Soon / Landing Pages)
ALLOWED_SHORT_DOMAINS=(
    "eksleks.com"
    "www.eksleks.com"
    "sabrina-missiria-group.com"
    "www.sabrina-missiria-group.com"
)

# Terminal Colors for Pro Output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}=================================================================${NC}"
echo -e "${BLUE}🚀 STARTING PRO NGINX DOMAIN MONITOR V3${NC}"
echo -e "${BLUE}=================================================================${NC}"

# --- PRO DOMAIN EXTRACTION ---
DOMAINS=$(awk '/^[ \t]*server_name/ {for (i=2; i<=NF; i++) { gsub(/;/, "", $i); print $i } }' "$NGINX_PATH"/* | sort -u)

# Prepare Report Variables
REPORT_EMAIL=""
ISSUE_COUNT=0
TOTAL_SITES=0

# Print Table Header
printf "%-35s | %-8s | %-8s | %-30s\n" "DOMAIN" "STATUS" "WORDS" "CONTENT REVEAL (First 5 words)"
printf "%-35s | %-8s | %-8s | %-30s\n" "-----------------------------------" "--------" "--------" "------------------------------"

for domain in $DOMAINS; do
    if [[ "$domain" == "_" || "$domain" == "localhost" || "$domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || -z "$domain" || "$domain" == "~"* ]]; then
        continue
    fi

    ((TOTAL_SITES++))

    # 1. Fetch HTTP Status
    HTTP_STATUS=$(curl -o /dev/null -s -w "%{http_code}" --max-time 10 "https://$domain")
    
    if [ "$HTTP_STATUS" == "000" ]; then
         HTTP_STATUS=$(curl -o /dev/null -s -w "%{http_code}" --max-time 10 "http://$domain")
         PROTOCOL="http"
    else
         PROTOCOL="https"
    fi

    # --- THE PRO LOGIC ROUTING ---
    
    # CASE A: Healthy Redirect (3xx)
    if [[ "$HTTP_STATUS" =~ ^30[1278]$ ]]; then
        TARGET=$(curl -s -L -o /dev/null -w "%{url_effective}" --max-time 10 "$PROTOCOL://$domain" | sed 's/https:\/\///g' | sed 's/http:\/\///g' | cut -d '/' -f 1)
        printf "${CYAN}%-35s | %-8s | %-8s | %-30s${NC}\n" "$domain" "$HTTP_STATUS" "---" "Redirects -> $TARGET"

    # CASE B: Active Site (200 OK)
    elif [ "$HTTP_STATUS" -eq 200 ]; then
        RAW_TEXT=$(curl -s --max-time 10 "$PROTOCOL://$domain" | perl -0777 -pe 's/<script\b[^>]*>.*?<\/script>//igs; s/<style\b[^>]*>.*?<\/style>//igs; s/<[^>]+>//g' | tr '\n' ' ' | tr -s ' ')
        
        WORD_COUNT=$(echo "$RAW_TEXT" | wc -w)
        SNIPPET=$(echo "$RAW_TEXT" | cut -d ' ' -f 1-5)
        
        # Check if the domain is in our authorized whitelist
        IS_WHITELISTED=0
        for allowed in "${ALLOWED_SHORT_DOMAINS[@]}"; do
            if [[ "$domain" == "$allowed" ]]; then
                IS_WHITELISTED=1
                break
            fi
        done
        
        # If it fails the word count AND is not on the whitelist, flag it
        if [ "$WORD_COUNT" -lt "$MIN_WORDS" ] && [ "$IS_WHITELISTED" -eq 0 ]; then
            printf "${YELLOW}%-35s | %-8s | %-8s | %-30s${NC}\n" "$domain" "$HTTP_STATUS" "$WORD_COUNT" "${SNIPPET:0:28}..."
            REPORT_EMAIL+="⚠️ $domain | LOW WORD COUNT ($WORD_COUNT/$MIN_WORDS) | Snippet: ${SNIPPET:0:20}\n"
            ((ISSUE_COUNT++))
        else
            # Green if it passes the word count naturally, OR if it's on the whitelist
            printf "${GREEN}%-35s | %-8s | %-8s | %-30s${NC}\n" "$domain" "$HTTP_STATUS" "$WORD_COUNT" "${SNIPPET:0:28}..."
        fi

    # CASE C: Dead or Broken (404, 500, etc.)
    else
        printf "${RED}%-35s | %-8s | %-8s | %-30s${NC}\n" "$domain" "$HTTP_STATUS" "---" "N/A (Error / Unreachable)"
        REPORT_EMAIL+="❌ $domain | Status: $HTTP_STATUS | Words: 0\n"
        ((ISSUE_COUNT++))
    fi
done

echo -e "${BLUE}=================================================================${NC}"
echo -e "Total Sites Scanned: $TOTAL_SITES"
echo -e "Total Issues Found: $ISSUE_COUNT"

# --- CONSOLIDATED POSTFIX ALERT ---
if [ "$ISSUE_COUNT" -gt 0 ]; then
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$TIMESTAMP] Found $ISSUE_COUNT issues across $TOTAL_SITES domains." >> "$LOG_FILE"
    
    EMAIL_BODY="Monitoring Report - $TIMESTAMP\n\n"
    EMAIL_BODY+="Total Sites Scanned: $TOTAL_SITES\n"
    EMAIL_BODY+="Total Issues Detected: $ISSUE_COUNT\n\n"
    EMAIL_BODY+="--- ISSUE DETAILS ---\n"
    EMAIL_BODY+="$REPORT_EMAIL\n\n"
    EMAIL_BODY+="Action Required: Check your Nginx configuration or server logs."

    echo -e "$EMAIL_BODY" | mail -s "🚨 NGINX ALERT: $ISSUE_COUNT Domains Require Attention" "$EMAIL_DEST"
    echo -e "${RED}Alert email dispatched to $EMAIL_DEST.${NC}"
else
    echo -e "${GREEN}All domains are healthy! No email sent.${NC}"
fi

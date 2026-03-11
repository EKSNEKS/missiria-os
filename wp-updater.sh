#!/bin/bash

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN} 🚀 OPCACHE-BUSTING WP UPGRADER & ERROR CATCHER      ${NC}"
echo -e "${GREEN}======================================================${NC}"

GLOBAL_START=$(date +%s)
WP_CONFIGS=$(find /var/www/ -name "wp-config.php" -type f 2>/dev/null)
DEAD_SITES=()

for CONFIG in $WP_CONFIGS; do
    SITE_START=$(date +%s)
    SITE_PATH=$(dirname "$CONFIG")
    DOMAIN=""

    # OPcache Buster: Generate a unique filename for this specific run
    TRIGGER_FILE="missiria-trigger-$RANDOM.php"

    NGINX_CONF=$(grep -Rl "$SITE_PATH" /etc/nginx/sites-enabled/ 2>/dev/null | head -n 1)
    if [ -n "$NGINX_CONF" ]; then
        DOMAIN=$(grep -E "^\s*server_name" "$NGINX_CONF" | head -n 1 | awk '{print $2}' | tr -d ';')
    fi

    if [ -z "$DOMAIN" ] || [ "$DOMAIN" == "_" ]; then
        continue
    fi

    HTTP_STATUS=$(curl -o /dev/null -s -w "%{http_code}" -L -m 5 "http://$DOMAIN")
    if [ "$HTTP_STATUS" -eq 000 ] || [ "$HTTP_STATUS" -ge 500 ]; then
        DEAD_SITES+=("$DOMAIN (Status: $HTTP_STATUS)")
        echo -e "${RED}[DEAD] $DOMAIN (Status: $HTTP_STATUS). Skipping.${NC}"
        continue
    fi

    echo -e "\n${YELLOW}▶ Processing: $DOMAIN${NC}"

    # ---------------------------------------------------------
    # NEW PAYLOAD WITH STRICT ERROR LOGGING
    # ---------------------------------------------------------
    cat << 'EOF' > "$SITE_PATH/$TRIGGER_FILE"
<?php
define('FS_METHOD', 'direct');
define('WP_USE_THEMES', false);
set_time_limit(900);

require('./wp-load.php');
require_once(ABSPATH . 'wp-admin/includes/admin.php');
require_once(ABSPATH . 'wp-admin/includes/file.php');
require_once(ABSPATH . 'wp-admin/includes/class-wp-upgrader.php');

$skin = new Automatic_Upgrader_Skin();
$logs = [];

wp_clean_update_cache();
delete_site_transient('update_core');
delete_site_transient('update_plugins');

// A. CORE WITH ERROR CATCHING
wp_version_check();
$core = get_core_updates();
if (isset($core[0]) && $core[0]->response == 'upgrade') {
    $cu = new Core_Upgrader($skin);
    $result = $cu->upgrade($core[0]);

    if (is_wp_error($result)) {
        $logs[] = "Core FAIL: " . $result->get_error_message();
    } elseif ($result === false) {
        $logs[] = "Core FAIL: Permissions or FS_METHOD blocked the write";
    } else {
        $logs[] = "Core: Updated to " . $core[0]->current;
    }
} else {
    $logs[] = "Core: Up-to-date";
}

// B. PLUGINS WITH ERROR CATCHING
wp_update_plugins();
$up = get_site_transient('update_plugins');
if (!empty($up->response)) {
    $pu = new Plugin_Upgrader($skin);
    $result = $pu->bulk_upgrade(array_keys($up->response));
    if (is_wp_error($result)) {
        $logs[] = "Plugins FAIL: " . $result->get_error_message();
    } else {
        $logs[] = "Plugins: " . count($up->response) . " updated";
    }
} else {
    $logs[] = "Plugins: 0 updates";
}

// C. LANGUAGES
$lp = wp_get_translation_updates();
if (!empty($lp)) {
    $lu = new Language_Pack_Upgrader($skin);
    $lu->bulk_upgrade($lp);
    $logs[] = "Languages: Done";
}

echo "LOG_DATA: " . implode(' | ', $logs);
EOF

    chown www-data:www-data "$SITE_PATH/$TRIGGER_FILE"

    # Execute dynamic file
    HTTP_RESP=$(curl -s -L -m 900 "http://$DOMAIN/$TRIGGER_FILE")

    SITE_END=$(date +%s)
    DURATION=$((SITE_END - SITE_START))
    UPDATE_TIME=$(date '+%Y/%m/%d %H:%M:%S')

    if [[ "$HTTP_RESP" == *"LOG_DATA"* ]]; then
        CLEAN_LOG=$(echo "$HTTP_RESP" | grep -o "LOG_DATA:.*")
        echo -e "${GREEN}✓ DONE in ${DURATION}s | $CLEAN_LOG${NC}"
        echo -e "  Updated at: ${UPDATE_TIME}"
    else
        echo -e "${RED}✗ FAIL in ${DURATION}s | Response: $HTTP_RESP${NC}"
        echo -e "  Attempted at: ${UPDATE_TIME}"
    fi

    # Cleanup
    rm -f "$SITE_PATH/$TRIGGER_FILE"
done

GLOBAL_END=$(date +%s)
TOTAL_TIME=$((GLOBAL_END - GLOBAL_START))
if [ ${#DEAD_SITES[@]} -gt 0 ]; then
    echo -e "\n${RED}Dead sites skipped during this run:${NC}"
    for DEAD_SITE in "${DEAD_SITES[@]}"; do
        echo -e "${RED}- $DEAD_SITE${NC}"
    done
fi

echo -e "\n${GREEN}======================================================${NC}"
echo -e "${GREEN} ✅ ALL SITES FINISHED IN ${TOTAL_TIME} SECONDS          ${NC}"
echo -e "${GREEN}======================================================${NC}"

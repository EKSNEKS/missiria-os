#!/bin/bash

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN} Restored Master Upgrader (Core + Plugins + Safe Check)${NC}"
echo -e "${GREEN}======================================================${NC}"

WP_CONFIGS=$(find /var/www/ -name "wp-config.php" -type f 2>/dev/null)

for CONFIG in $WP_CONFIGS; do
    SITE_PATH=$(dirname "$CONFIG")
    DOMAIN=""

    # Detect Domain from Nginx
    NGINX_CONF=$(grep -Rl "$SITE_PATH" /etc/nginx/sites-enabled/ 2>/dev/null | head -n 1)
    if [ -n "$NGINX_CONF" ]; then
        DOMAIN=$(grep -E "^\s*server_name" "$NGINX_CONF" | head -n 1 | awk '{print $2}' | tr -d ';')
    fi

    if [ -z "$DOMAIN" ] || [ "$DOMAIN" == "_" ]; then
        echo -e "${RED}Skipping -> $SITE_PATH (No Domain Found)${NC}"
        continue
    fi

    # --- FEATURE: DEAD SITE DETECTION ---
    # Check if the site is actually alive before wasting time
    HTTP_STATUS=$(curl -o /dev/null -s -w "%{http_code}" -L -m 5 "http://$DOMAIN")
    if [ "$HTTP_STATUS" -eq 000 ] || [ "$HTTP_STATUS" -ge 500 ]; then
        echo -e "${RED}DEAD SITE -> $DOMAIN (Status: $HTTP_STATUS). Skipping.${NC}"
        continue
    fi

    echo -e "\n${YELLOW}Processing -> $DOMAIN (Path: $SITE_PATH)${NC}"

    # ---------------------------------------------------------
    # IMPROVED PHP PAYLOAD
    # ---------------------------------------------------------
    cat << 'EOF' > "$SITE_PATH/missiria-trigger.php"
<?php
define('FS_METHOD', 'direct');
define('WP_USE_THEMES', false);
set_time_limit(600); // 10 minutes for slow core updates

require('./wp-load.php');
require_once(ABSPATH . 'wp-admin/includes/admin.php');
require_once(ABSPATH . 'wp-admin/includes/file.php');
require_once(ABSPATH . 'wp-admin/includes/class-wp-upgrader.php');

$skin = new Automatic_Upgrader_Skin();
$results = [];

// 1. Clear Cache & Force Checks
wp_clean_update_cache();
wp_version_check();
wp_update_plugins();

// 2. CORE UPDATE
$core_updates = get_core_updates();
if (isset($core_updates[0]) && $core_updates[0]->response == 'upgrade') {
    $core_upgrader = new Core_Upgrader($skin);
    $core_upgrader->upgrade($core_updates[0]);
    $results[] = "Core Updated";
}

// 3. PLUGINS
$plugin_updates = get_site_transient('update_plugins');
if (!empty($plugin_updates->response)) {
    $plugin_upgrader = new Plugin_Upgrader($skin);
    $plugin_upgrader->bulk_upgrade(array_keys($plugin_updates->response));
    $results[] = "Plugins Updated";
}

// 4. TRANSLATIONS
$language_updates = wp_get_translation_updates();
if (!empty($language_updates)) {
    $language_upgrader = new Language_Pack_Upgrader($skin);
    $language_upgrader->bulk_upgrade($language_updates);
    $results[] = "Languages Updated";
}

echo "TRIGGER_OK: " . implode(', ', $results);
EOF

    chown www-data:www-data "$SITE_PATH/missiria-trigger.php"

    # Run the trigger with a longer timeout for Core updates
    HTTP_RESP=$(curl -s -L -m 600 "http://$DOMAIN/missiria-trigger.php")

    if [[ "$HTTP_RESP" == *"TRIGGER_OK"* ]]; then
        echo -e "${GREEN}✓ SUCCESS on $DOMAIN! Details: $HTTP_RESP${NC}"
    else
        # Handle cases where it says "OK" but doesn't match the new trigger tag
        echo -e "${RED}✗ FAIL on $DOMAIN. Response: $HTTP_RESP${NC}"
    fi

    rm -f "$SITE_PATH/missiria-trigger.php"
    sleep 2
done
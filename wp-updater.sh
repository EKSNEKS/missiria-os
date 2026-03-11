#!/bin/bash

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN} Forcing FULL Upgrades (Core + Plugins + Languages)   ${NC}"
echo -e "${GREEN}======================================================${NC}"

WP_CONFIGS=$(find /var/www/ -name "wp-config.php" -type f 2>/dev/null)

if [ -z "$WP_CONFIGS" ]; then
    echo -e "${RED}Error: No wp-config.php files found.${NC}"
    exit 1
fi

for CONFIG in $WP_CONFIGS; do

    DOMAIN=""
    SITE_PATH=$(dirname "$CONFIG")
    NGINX_CONF=$(grep -Rl "$SITE_PATH" /etc/nginx/sites-enabled/ 2>/dev/null | head -n 1)

    if [ -n "$NGINX_CONF" ]; then
        DOMAIN=$(grep -E "^\s*server_name" "$NGINX_CONF" | head -n 1 | awk '{print $2}' | tr -d ';')
    fi

    if [ -z "$DOMAIN" ] || [ "$DOMAIN" == "_" ]; then
        continue
    fi

    echo -e "\n${YELLOW}Checking -> $DOMAIN${NC}"

    # ---------------------------------------------------------
    # INJECTING THE FULL POWER PAYLOAD
    # ---------------------------------------------------------
    cat << 'EOF' > "$SITE_PATH/missiria-trigger.php"
<?php
define('FS_METHOD', 'direct');
define('WP_USE_THEMES', false);
set_time_limit(300);

require('./wp-load.php');
require_once(ABSPATH . 'wp-admin/includes/admin.php');
require_once(ABSPATH . 'wp-admin/includes/file.php');
require_once(ABSPATH . 'wp-admin/includes/class-wp-upgrader.php');

// 0. Aggressive Cache Clear
wp_clean_update_cache();
delete_site_transient('update_core');
delete_site_transient('update_plugins');
wp_version_check();
wp_update_plugins();

$skin = new Automatic_Upgrader_Skin();

// 1. FORCE CORE UPDATE (Fixes the 6.9.1 -> 6.9.3 issue)
$core_updates = get_core_updates();
if (isset($core_updates[0]) && $core_updates[0]->response == 'upgrade') {
    $core_upgrader = new Core_Upgrader($skin);
    $core_upgrader->upgrade($core_updates[0]);
}

// 2. PLUGINS
$plugin_updates = get_site_transient('update_plugins');
if (!empty($plugin_updates->response)) {
    $plugin_upgrader = new Plugin_Upgrader($skin);
    $plugin_upgrader->bulk_upgrade(array_keys($plugin_updates->response));
}

// 3. TRANSLATIONS
$language_updates = wp_get_translation_updates();
if (!empty($language_updates)) {
    $language_upgrader = new Language_Pack_Upgrader($skin);
    $language_upgrader->bulk_upgrade($language_updates);
}

echo "OK_COMPLETE";
EOF

    chown www-data:www-data "$SITE_PATH/missiria-trigger.php"

    # Run the trigger
    HTTP_RESP=$(curl -s -L -m 300 "http://$DOMAIN/missiria-trigger.php")

    if [[ "$HTTP_RESP" == *"OK_COMPLETE"* ]]; then
        echo -e "${GREEN}✓ FULL Success on $DOMAIN!${NC}"
    else
        echo -e "${RED}✗ Error on $DOMAIN. Response: $HTTP_RESP${NC}"
    fi

    # Cleanup
    rm -f "$SITE_PATH/missiria-trigger.php"
done
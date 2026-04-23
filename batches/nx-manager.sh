#!/bin/bash

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m❌ Please run as root (or use sudo).\033[0m"
    exit 1
fi

# Terminal Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- HELPER FUNCTIONS ---

print_header() {
    printf '%b\n' "${CYAN}______  ____________________________________________________${NC}"
    printf '%b\n' "${CYAN}___   |/  /___  _/_  ___/_  ___/___  _/__  __ \___  _/__    |${NC}"
    printf '%b\n' "${CYAN}__  /|_/ / __  / _____ \_____ \ __  / __  /_/ /__  / __  /| |${NC}"
    printf '%b\n' "${CYAN}_  /  / / __/ /  ____/ /____/ /__/ /  _  _, _/__/ /  _  ___ |${NC}"
    printf '%b\n' "${CYAN}/_/  /_/  /___/  /____/ /____/ /___/  /_/ |_| /___/  /_/  |_|${NC}"
    printf '%b\n' "${CYAN}                                                           v3${NC}"
    printf '%b\n' "${GREEN}NGINX MANAGER${NC}"
}

update_domain() {
    DOMAIN=$1
    AVAIL="/etc/nginx/sites-available/$DOMAIN"
    ENABLED="/etc/nginx/sites-enabled/$DOMAIN"

    if [ ! -f "$AVAIL" ]; then
        echo -e "${RED}❌ Error: Configuration for $DOMAIN not found in sites-available.${NC}"
        return
    fi

    if [ -L "$ENABLED" ] || [ -f "$ENABLED" ]; then
        echo -e "${CYAN}🔄 Refreshing existing link for $DOMAIN...${NC}"
        rm "$ENABLED"
    fi

    ln -s "$AVAIL" "$ENABLED"
    echo -e "${GREEN}✅ Symlink created for $DOMAIN.${NC}"

    echo "Testing Nginx configuration..."
    if nginx -t; then
        systemctl reload nginx
        echo -e "${GREEN}🚀 SUCCESS: $DOMAIN is now live and Nginx reloaded!${NC}"
    else
        echo -e "${RED}⚠️ CRITICAL: Nginx config test failed. Reverting link...${NC}"
        rm "$ENABLED"
    fi
}

delete_domain() {
    DOMAIN=$1
    AVAIL="/etc/nginx/sites-available/$DOMAIN"
    ENABLED="/etc/nginx/sites-enabled/$DOMAIN"

    echo -e "${CYAN}🔄 Removing existing links and configs for $DOMAIN...${NC}"

    if [ -L "$ENABLED" ]; then
        rm "$ENABLED"
        echo -e "${GREEN}✅ Symlink removed for $DOMAIN.${NC}"
    else
        echo -e "${YELLOW}⚠️ No symlink found in sites-enabled.${NC}"
    fi

    if [ -f "$AVAIL" ]; then
        rm "$AVAIL"
        echo -e "${GREEN}✅ Configuration file deleted from sites-available.${NC}"
    else
        echo -e "${YELLOW}⚠️ No config file found in sites-available.${NC}"
    fi

    echo "Testing Nginx configuration..."
    if nginx -t; then
        systemctl reload nginx
        echo -e "${GREEN}🚀 SUCCESS: $DOMAIN has been removed and Nginx reloaded!${NC}"
    else
        echo -e "${RED}❌ ERROR: Nginx configuration test failed. Reload aborted.${NC}"
    fi
}

insert_domain() {
    DOMAIN=$1
    read -p "Enter the web root directory (Default: /var/www/MISSIRIA/$DOMAIN): " WEB_ROOT
    WEB_ROOT=${WEB_ROOT:-/var/www/MISSIRIA/$DOMAIN}

    AVAIL="/etc/nginx/sites-available/$DOMAIN"

    if [ -f "$AVAIL" ]; then
        echo -e "${RED}❌ Error: A configuration for $DOMAIN already exists!${NC}"
        return
    fi

    echo -e "${CYAN}📁 Creating directory $WEB_ROOT...${NC}"
    mkdir -p "$WEB_ROOT"
    chown -R www-data:www-data "$WEB_ROOT"
    chmod -R 755 "$WEB_ROOT"

    echo -e "${CYAN}📝 Generating Nginx configuration for WordPress/PHP...${NC}"

    cat > "$AVAIL" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;
    root $WEB_ROOT;
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.1-fpm.sock; # Adjust PHP version if necessary
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

    echo -e "${GREEN}✅ Nginx configuration generated at $AVAIL${NC}"

    # Automatically update/link the newly created domain
    update_domain "$DOMAIN"
}

enable_varnish() {
    DOMAIN=$1
    AVAIL="/etc/nginx/sites-available/$DOMAIN"

    if [ ! -f "$AVAIL" ]; then
        echo -e "${RED}❌ Error: Configuration for $DOMAIN not found in sites-available.${NC}"
        return
    fi

    echo -e "${CYAN}📦 Backing up original configuration to ${AVAIL}.bak...${NC}"
    cp "$AVAIL" "${AVAIL}.bak"

    read -p "Enter the web root directory (Default: /var/www/MISSIRIA/$DOMAIN): " WEB_ROOT
    WEB_ROOT=${WEB_ROOT:-/var/www/MISSIRIA/$DOMAIN}
    read -p "Enter PHP version for backend (Default: 8.3): " PHP_VER
    PHP_VER=${PHP_VER:-8.3}

    echo -e "${CYAN}📝 Injecting Varnish Architecture into Nginx configuration...${NC}"
    
    cat > "$AVAIL" <<EOF
# ---------------------------------------------------------
# 1. THE BACKEND (Port 8080)
# ---------------------------------------------------------
server {
    listen 8080;
    server_name $DOMAIN www.$DOMAIN;
    root $WEB_ROOT;
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }

    # Webmail
    include /etc/nginx/snippets/roundcube-webmail.conf;
}

# ---------------------------------------------------------
# 2. THE FRONT DOOR (Port 443 -> 6081)
# ---------------------------------------------------------
server {
    listen [::]:443 ssl;
    listen 443 ssl;
    server_name $DOMAIN www.$DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://127.0.0.1:6081;
        
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port 443;
    }
}
EOF

    echo -e "${GREEN}✅ Varnish configuration applied for $DOMAIN.${NC}"
    
    # Reload Nginx using your existing function
    update_domain "$DOMAIN"

    echo -e "${CYAN}🔍 Executing curl test for Varnish Cache...${NC}"
    sleep 2 # Give Nginx a second to breathe
    
    HEADERS=$(curl -I -s "https://$DOMAIN")
    
    if echo "$HEADERS" | grep -i 'x-varnish' > /dev/null; then
        echo -e "${GREEN}🚀 SUCCESS: Varnish is ACTIVE! Here are your cache headers:${NC}"
        echo "$HEADERS" | grep -i -E 'x-cache|age|x-varnish|via'
    else
        echo -e "${RED}⚠️ WARNING: Varnish headers not detected. Ensure Certbot SSL files exist for this domain.${NC}"
    fi
}

# --- MAIN MENU UI ---

clear
print_header
echo
echo -e "${BLUE}1)${NC} Update / Reload Server Nginx (Synginx)"
echo -e "${BLUE}2)${NC} Delete Server Nginx (Delginx)"
echo -e "${BLUE}3)${NC} Insert / Create New Domain"
echo -e "${BLUE}4)${NC} Deploy & Test Varnish Cache"
echo -e "${BLUE}5)${NC} Exit"
read -p "Select an option [1-5]: " OPTION

case $OPTION in
    1)
        read -p "Enter the domain to UPDATE: " INPUT_DOMAIN
        [[ -n "$INPUT_DOMAIN" ]] && update_domain "$INPUT_DOMAIN" || echo -e "${RED}Domain required.${NC}"
        ;;
    2)
        read -p "Enter the domain to DELETE: " INPUT_DOMAIN
        [[ -n "$INPUT_DOMAIN" ]] && delete_domain "$INPUT_DOMAIN" || echo -e "${RED}Domain required.${NC}"
        ;;
    3)
        read -p "Enter the NEW domain to INSERT: " INPUT_DOMAIN
        [[ -n "$INPUT_DOMAIN" ]] && insert_domain "$INPUT_DOMAIN" || echo -e "${RED}Domain required.${NC}"
        ;;
    4)
        read -p "Enter the domain to ACTIVATE VARNISH for: " INPUT_DOMAIN
        [[ -n "$INPUT_DOMAIN" ]] && enable_varnish "$INPUT_DOMAIN" || echo -e "${RED}Domain required.${NC}"
        ;;
    5)
        echo -e "${GREEN}Exiting...${NC}"
        exit 0
        ;;
    *)
        echo -e "${RED}❌ Invalid option. Exiting.${NC}"
        exit 1
        ;;
esac

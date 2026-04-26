#!/bin/bash

DOMAIN=$1
USER=$2
PASSWORD=$3

# Conversion des tirets en underscores pour le nom système (indispensable)
# FULL_USER="${USER}_$(echo $DOMAIN | cut -d'.' -f1 | tr '-' '_')" # ERROR of the oldest, stealthiest hard limits in Linux, and your debugging instincts

# Conversion des tirets en underscores pour le nom système
RAW_USER="${USER}_$(echo $DOMAIN | cut -d'.' -f1 | tr '-' '_')"

# Truncate to 32 characters to prevent Linux useradd failures
FULL_USER="${RAW_USER:0:32}"

if [ -z "$DOMAIN" ] || [ -z "$USER" ]; then
    echo "Usage: ./create_webmail.sh domain.com username [password]"
    exit 1
fi

# Auto-generate a password if you don't provide one
if [ -z "$PASSWORD" ]; then
    PASSWORD=$(openssl rand -base64 12)
    GENERATED_PASS=true
fi

echo "--- 🛠️  Configuring $DOMAIN ---"

# 1. Postfix Master Patch (virtual_alias_domains)
CURRENT_DOMAINS=$(postconf -h virtual_alias_domains)
if [[ $CURRENT_DOMAINS != *"$DOMAIN"* ]]; then
    echo "➕ Adding $DOMAIN to virtual_alias_domains..."
    if [ -z "$CURRENT_DOMAINS" ]; then
        NEW_LIST="$DOMAIN"
    else
        NEW_LIST="${CURRENT_DOMAINS}, ${DOMAIN}"
    fi
    sudo postconf -e "virtual_alias_domains = $NEW_LIST"
fi

# 2. Gestion de l'utilisateur système (Non-Interactive Password)
if id "$FULL_USER" &>/dev/null; then
    echo "ℹ️  System user $FULL_USER already exists, skipping creation."
    # Optional: If you want it to forcefully update the password even if the user exists, 
    # you can move the chpasswd line out of the 'else' block.
else
    echo "👤 Creating system user $FULL_USER..."
    sudo useradd -m -s /usr/sbin/nologin $FULL_USER
    
    # MAGIC HAPPENS HERE: Piping the password non-interactively
    echo "$FULL_USER:$PASSWORD" | sudo chpasswd
    echo "✅ Password set successfully."
fi

# 3. Protection contre les doublons dans /etc/postfix/virtual
if grep -q "^${USER}@${DOMAIN}" /etc/postfix/virtual; then
    echo "✅ Alias ${USER}@${DOMAIN} already exists in virtual maps."
else
    echo "📝 Adding alias to virtual maps..."
    echo "${USER}@${DOMAIN} ${FULL_USER}" | sudo tee -a /etc/postfix/virtual
    sudo postmap /etc/postfix/virtual
fi

# 4. Correctif des permissions (Évite l'erreur STORAGE dans Roundcube)
echo "📂 Fixing Maildir permissions..."
sudo mkdir -p /home/$FULL_USER/Maildir/{cur,new,tmp}
sudo chown -R $FULL_USER:$FULL_USER /home/$FULL_USER/Maildir
sudo chmod -R 700 /home/$FULL_USER/Maildir

# 5. Restart
sudo systemctl restart postfix dovecot

echo "--- 🚀 SUCCESS: ${USER}@${DOMAIN} is live! ---"
echo "📧 Email: ${USER}@${DOMAIN}"

if [ "$GENERATED_PASS" = true ]; then
    echo -e "🔑 \033[0;32mGenerated Password:\033[0m $PASSWORD"
else
    echo -e "🔑 \033[0;32mPassword:\033[0m (As provided)"
fi
echo "----------------------------------------------"

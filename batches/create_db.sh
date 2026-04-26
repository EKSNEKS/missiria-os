#!/bin/bash

# Configuration - Update these or ensure ~/.my.cnf is configured
DB_USER="${DB_USER:-missiria}"
MYSQL_ADMIN_USER="${MYSQL_ADMIN_USER:-root}"
MYSQL_ADMIN_PASS="${MYSQL_ADMIN_PASS:-}"
MYSQL_BIN="${MYSQL_BIN:-mysql}"
DEFAULT_GRANT_USER="${DEFAULT_GRANT_USER:-missiria}"
DEFAULT_GRANT_HOST="${DEFAULT_GRANT_HOST:-localhost}"

quote_identifier() {
    local value="$1"
    value="${value//\`/\`\`}"
    printf '`%s`' "$value"
}

escape_literal() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\'/\'\'}"
    printf '%s' "$value"
}

# 1. Show all existing databases
echo "--- Existing Databases ---"
MYSQL_PWD="$MYSQL_ADMIN_PASS" "$MYSQL_BIN" -u "$MYSQL_ADMIN_USER" -e "SHOW DATABASES;"

echo ""

# 2. Ask for the name of the new database
read -r -p "Enter the name of the new database to create: " DB_NAME

# Validation: Ensure the input isn't empty
if [ -z "$DB_NAME" ]; then
    echo "Error: Database name cannot be empty."
    exit 1
fi

DB_IDENTIFIER="$(quote_identifier "$DB_NAME")"
GRANT_ACCESS="y"

read -r -p "Grant DB permissions to a user? [Y/n]: " GRANT_ACCESS
GRANT_ACCESS="${GRANT_ACCESS:-y}"

if [[ "$GRANT_ACCESS" =~ ^[Yy]$ ]]; then
    read -r -p "MySQL user to grant access to [$DEFAULT_GRANT_USER]: " NEW_USER
    NEW_USER="${NEW_USER:-$DEFAULT_GRANT_USER}"

    read -r -p "Host for '$NEW_USER' [$DEFAULT_GRANT_HOST]: " HOST
    HOST="${HOST:-$DEFAULT_GRANT_HOST}"

    NEW_USER_ESCAPED="$(escape_literal "$NEW_USER")"
    HOST_ESCAPED="$(escape_literal "$HOST")"

    echo "Creating database and granting privileges..."

    if MYSQL_PWD="$MYSQL_ADMIN_PASS" "$MYSQL_BIN" -u "$MYSQL_ADMIN_USER" <<EOF
CREATE DATABASE IF NOT EXISTS ${DB_IDENTIFIER};
GRANT ALL PRIVILEGES ON ${DB_IDENTIFIER}.* TO '${NEW_USER_ESCAPED}'@'${HOST_ESCAPED}';
FLUSH PRIVILEGES;
EOF
    then
        echo "Successfully created '$DB_NAME' and granted privileges to '$NEW_USER'@'$HOST'."
    else
        echo "An error occurred while creating the database or granting permissions."
        exit 1
    fi
else
    echo "Creating database without additional grants..."

    if MYSQL_PWD="$MYSQL_ADMIN_PASS" "$MYSQL_BIN" -u "$MYSQL_ADMIN_USER" -e "CREATE DATABASE IF NOT EXISTS ${DB_IDENTIFIER};"; then
        echo "Successfully created '$DB_NAME'."
    else
        echo "An error occurred while creating the database."
        exit 1
    fi
fi

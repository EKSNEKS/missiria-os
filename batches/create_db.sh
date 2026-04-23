#!/bin/bash

# Configuration - Update these or ensure ~/.my.cnf is configured
DB_USER="root"
NEW_USER="missiria"
HOST="localhost"

# 1. Show all existing Databases
echo "--- Existing Databases ---"
mysql -u "$DB_USER" -e "SHOW DATABASES;"

echo ""

# 2. Ask for the name of the new Database
read -p "Enter the name of the new database to create: " DB_NAME

# Validation: Ensure the input isn't empty
if [ -z "$DB_NAME" ]; then
    echo "Error: Database name cannot be empty."
    exit 1
fi

# 3. Execute Creation and Grant Privileges
echo "Creating database and granting privileges..."

mysql -u "$DB_USER" <<EOF
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$NEW_USER'@'$HOST';
FLUSH PRIVILEGES;
EOF

if [ $? -eq 0 ]; then
    echo "Successfully created '$DB_NAME' and granted privileges to '$NEW_USER'."
else
    echo "An error occurred during the SQL execution."
fi

#!/bin/bash

# Configuration
DB_USER="root"

# 1. Show all Databases
echo "--- Available Databases ---"
mysql -u "$DB_USER" -e "SHOW DATABASES;"
echo ""

# 2. Ask which DB to scan
read -p "Enter the name of the database you want to scan: " TARGET_DB

# Check if DB exists
DB_EXISTS=$(mysql -u "$DB_USER" -e "SHOW DATABASES LIKE '$TARGET_DB';" | grep "$TARGET_DB")
if [ -z "$DB_EXISTS" ]; then
    echo "Error: Database '$TARGET_DB' not found."
    exit 1
fi

echo "--- Scanning $TARGET_DB for domains/URLs ---"

# 3. Get all tables and columns, then search for URL patterns
# This query looks for http/https in any VARCHAR, TEXT, or LONGTEXT column
TABLES_COLS=$(mysql -u "$DB_USER" -N -e "
    SELECT TABLE_NAME, COLUMN_NAME 
    FROM information_schema.COLUMNS 
    WHERE TABLE_SCHEMA = '$TARGET_DB' 
    AND DATA_TYPE IN ('varchar', 'text', 'longtext', 'mediumtext');")

while read -r TABLE COLUMN; do
    # Run a query to find unique URLs in each column
    # We use REGEXP to grab the domain part specifically
    RESULTS=$(mysql -u "$DB_USER" -D "$TARGET_DB" -N -e "
        SELECT DISTINCT REGEXP_SUBSTR($COLUMN, 'https?://[^/\"\' >]+') 
        FROM \`$TABLE\` 
        WHERE $COLUMN REGEXP 'https?://' 
        AND REGEXP_SUBSTR($COLUMN, 'https?://[^/\"\' >]+') IS NOT NULL;")

    if [ ! -z "$RESULTS" ]; then
        echo -e "\n[Table: $TABLE | Field: $COLUMN]"
        echo "$RESULTS"
    fi
done <<< "$TABLES_COLS"

echo -e "\n--- Scan Complete ---"

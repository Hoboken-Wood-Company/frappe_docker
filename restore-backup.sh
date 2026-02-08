#!/bin/bash

set -e

SITE_NAME="${SITE_NAME:-erpnext.hobowo.co}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"
BACKUP_DIR="/home/frappe/backups"

echo "=========================================="
echo "Frappe Backup Restoration Script"
echo "=========================================="
echo ""

cd /home/frappe/frappe-bench

# List available backups in the backup directory
echo ""
echo "Available backups in ${BACKUP_DIR}:"
echo ""
ls -lh "$BACKUP_DIR" 2>/dev/null || echo "No backup files found. Please run load-backup.sh first."

# Auto-detect backup files
DEFAULT_DB_BACKUP=$(find "$BACKUP_DIR" -maxdepth 1 -name "*.sql.gz" -printf "%f\n" 2>/dev/null | head -1)
DEFAULT_PRIVATE_FILES=$(find "$BACKUP_DIR" -maxdepth 1 -name "*private*.tar" -printf "%f\n" 2>/dev/null | head -1)
DEFAULT_PUBLIC_FILES=$(find "$BACKUP_DIR" -maxdepth 1 -name "*files*.tar" ! -name "*private*" -printf "%f\n" 2>/dev/null | head -1)

echo ""
if [ -n "$DEFAULT_DB_BACKUP" ]; then
    echo "Enter the filename of your database backup [$DEFAULT_DB_BACKUP]:"
else
    echo "Enter the filename of your database backup (e.g., database.sql.gz):"
fi
read -r DB_BACKUP_FILE
DB_BACKUP_FILE="${DB_BACKUP_FILE:-$DEFAULT_DB_BACKUP}"

if [ -z "$DB_BACKUP_FILE" ]; then
    echo "Error: No backup file provided"
    exit 1
fi

if [ ! -f "$BACKUP_DIR/$DB_BACKUP_FILE" ]; then
    echo "Error: Backup file not found: $BACKUP_DIR/$DB_BACKUP_FILE"
    exit 1
fi

# Prompt for private files backup
echo ""
if [ -n "$DEFAULT_PRIVATE_FILES" ]; then
    echo "Enter the filename of your private files backup [$DEFAULT_PRIVATE_FILES] (or 'skip'):"
else
    echo "Enter the filename of your private files backup (or press enter to skip):"
fi
read -r PRIVATE_FILES
if [ "$PRIVATE_FILES" = "skip" ]; then
    PRIVATE_FILES=""
else
    PRIVATE_FILES="${PRIVATE_FILES:-$DEFAULT_PRIVATE_FILES}"
fi

# Prompt for public files backup
echo ""
if [ -n "$DEFAULT_PUBLIC_FILES" ]; then
    echo "Enter the filename of your public files backup [$DEFAULT_PUBLIC_FILES] (or 'skip'):"
else
    echo "Enter the filename of your public files backup (or press enter to skip):"
fi
read -r PUBLIC_FILES
if [ "$PUBLIC_FILES" = "skip" ]; then
    PUBLIC_FILES=""
else
    PUBLIC_FILES="${PUBLIC_FILES:-$DEFAULT_PUBLIC_FILES}"
fi

# Step 1: Create new site
echo ""
echo "Step 1: Creating site ${SITE_NAME}..."
bench new-site "$SITE_NAME" \
    --force \
    --mariadb-root-password 123 \
    --admin-password "$ADMIN_PASSWORD" \
    --no-mariadb-socket

# Step 2: Install apps BEFORE restore so the DB knows about them
echo ""
echo "Step 2: Installing apps before restore..."
bench --site "$SITE_NAME" install-app erpnext

# Step 3: Restore database with --force to bypass version check
echo ""
echo "Step 3: Restoring database backup..."
bench --site "$SITE_NAME" restore --force "$BACKUP_DIR/$DB_BACKUP_FILE"

# Step 4: Preserve encryption key from backup site_config if available
echo ""
echo "Step 4: Checking encryption key..."
SITE_CONFIG="sites/${SITE_NAME}/site_config.json"
if [ -f "$SITE_CONFIG" ]; then
    # bench restore may overwrite site_config.json — ensure Docker settings are intact
    echo "Verifying site_config.json has required Docker settings..."
    bench set-config -g db_host mariadb 2>/dev/null || true
    bench set-config -gp db_port 3306 2>/dev/null || true
    bench set-config -g redis_cache "redis://redis:6379" 2>/dev/null || true
    bench set-config -g redis_queue "redis://redis:6379" 2>/dev/null || true
    bench set-config -g redis_socketio "redis://redis:6379" 2>/dev/null || true
fi

# Step 5: Restore files if provided
echo ""
echo "Step 5: Restoring files..."
if [ -n "$PRIVATE_FILES" ] && [ -f "$BACKUP_DIR/$PRIVATE_FILES" ]; then
    echo "Restoring private files..."
    tar -xf "$BACKUP_DIR/$PRIVATE_FILES" -C "sites/${SITE_NAME}/private/"
else
    echo "No private files to restore."
fi

if [ -n "$PUBLIC_FILES" ] && [ -f "$BACKUP_DIR/$PUBLIC_FILES" ]; then
    echo "Restoring public files..."
    tar -xf "$BACKUP_DIR/$PUBLIC_FILES" -C "sites/${SITE_NAME}/public/"
else
    echo "No public files to restore."
fi

# Step 6: Run migrations to reconcile any schema differences
echo ""
echo "Step 6: Running migrations..."
bench --site "$SITE_NAME" migrate --skip-failing

# Step 7: Clear cache and set as default
echo ""
echo "Step 7: Finalizing..."
bench --site "$SITE_NAME" clear-cache
bench use "$SITE_NAME"

echo ""
echo "=========================================="
echo "Restoration complete!"
echo "=========================================="
echo ""
echo "Site: ${SITE_NAME}"
echo "Admin password: ${ADMIN_PASSWORD}"
echo "URL: http://localhost:8000"
echo ""
echo "Note: You may need to restart the bench for changes to take effect:"
echo "  docker compose restart frappe"
echo ""

#!/bin/bash

set -e

echo "=========================================="
echo "Frappe Backup Loader"
echo "=========================================="
echo ""

# Load environment variables from .env file if it exists
if [ -f .env ]; then
    echo "Loading environment from .env file..."
    set -a
    source <(grep -v '^#' .env | grep -v '^$')
    set +a
fi

# Check for AWS CLI
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI not found. Please install it first:"
    echo "  sudo apt install awscli"
    exit 1
fi

# Default S3 bucket and backup paths
S3_BUCKET="${S3_BUCKET:-frappe-hwc-backup}"
DEFAULT_BACKUP_PREFIX="20251221_174450"
HARDCODED_DB_PATH="${DEFAULT_BACKUP_PREFIX}/${DEFAULT_BACKUP_PREFIX}-hrms_localhost-database.sql.gz"
HARDCODED_PRIVATE_PATH="${DEFAULT_BACKUP_PREFIX}/${DEFAULT_BACKUP_PREFIX}-hrms_localhost-private-files.tar"
HARDCODED_PUBLIC_PATH="${DEFAULT_BACKUP_PREFIX}/${DEFAULT_BACKUP_PREFIX}-hrms_localhost-files.tar"

# List available backups in S3
echo "Available backups in s3://${S3_BUCKET}:"
echo ""
S3_LISTING=$(aws s3 ls "s3://${S3_BUCKET}/" --recursive | grep -E '\.(sql|gz|tar)$' | tail -20)
echo "$S3_LISTING"

# Auto-detect backup files from listing, fall back to hardcoded defaults
DEFAULT_DB_PATH=$(echo "$S3_LISTING" | grep -E '\.sql\.gz$' | tail -1 | awk '{print $NF}')
DEFAULT_DB_PATH="${DEFAULT_DB_PATH:-$HARDCODED_DB_PATH}"
DEFAULT_PRIVATE_PATH=$(echo "$S3_LISTING" | grep -E 'private.*\.tar$' | tail -1 | awk '{print $NF}')
DEFAULT_PRIVATE_PATH="${DEFAULT_PRIVATE_PATH:-$HARDCODED_PRIVATE_PATH}"
DEFAULT_PUBLIC_PATH=$(echo "$S3_LISTING" | grep -E '\.tar$' | grep -v 'private' | tail -1 | awk '{print $NF}')
DEFAULT_PUBLIC_PATH="${DEFAULT_PUBLIC_PATH:-$HARDCODED_PUBLIC_PATH}"

echo ""
if [ -n "$DEFAULT_DB_PATH" ]; then
    echo "Enter the S3 path to your database backup [$DEFAULT_DB_PATH]:"
else
    echo "Enter the S3 path to your database backup (e.g., backups/20240101/database.sql.gz):"
fi
read -r DB_BACKUP_PATH
DB_BACKUP_PATH="${DB_BACKUP_PATH:-$DEFAULT_DB_PATH}"

if [ -z "$DB_BACKUP_PATH" ]; then
    echo "Error: No backup path provided"
    exit 1
fi

# Create temporary directory
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Download database backup
echo ""
echo "Downloading database backup..."
aws s3 cp "s3://${S3_BUCKET}/${DB_BACKUP_PATH}" "$TEMP_DIR/database.sql.gz"

# Prompt for private files backup
echo ""
if [ -n "$DEFAULT_PRIVATE_PATH" ]; then
    echo "Enter the S3 path to your private files backup [$DEFAULT_PRIVATE_PATH] (or 'skip'):"
else
    echo "Enter the S3 path to your private files backup (or press enter to skip):"
fi
read -r PRIVATE_FILES_PATH
if [ "$PRIVATE_FILES_PATH" = "skip" ]; then
    PRIVATE_FILES_PATH=""
else
    PRIVATE_FILES_PATH="${PRIVATE_FILES_PATH:-$DEFAULT_PRIVATE_PATH}"
fi

# Prompt for public files backup
echo ""
if [ -n "$DEFAULT_PUBLIC_PATH" ]; then
    echo "Enter the S3 path to your public files backup [$DEFAULT_PUBLIC_PATH] (or 'skip'):"
else
    echo "Enter the S3 path to your public files backup (or press enter to skip):"
fi
read -r PUBLIC_FILES_PATH
if [ "$PUBLIC_FILES_PATH" = "skip" ]; then
    PUBLIC_FILES_PATH=""
else
    PUBLIC_FILES_PATH="${PUBLIC_FILES_PATH:-$DEFAULT_PUBLIC_PATH}"
fi

if [ -n "$PRIVATE_FILES_PATH" ]; then
    echo "Downloading private files..."
    aws s3 cp "s3://${S3_BUCKET}/${PRIVATE_FILES_PATH}" "$TEMP_DIR/private-files.tar"
fi

if [ -n "$PUBLIC_FILES_PATH" ]; then
    echo "Downloading public files..."
    aws s3 cp "s3://${S3_BUCKET}/${PUBLIC_FILES_PATH}" "$TEMP_DIR/public-files.tar"
fi

# Copy files to Docker volume
echo ""
echo "Copying backups to Docker volume..."

# Get the running frappe container name
CONTAINER_NAME=$(docker compose ps -q frappe)

if [ -z "$CONTAINER_NAME" ]; then
    echo "Error: frappe container is not running"
    echo "Please start the containers first: docker compose up -d"
    exit 1
fi

# Copy files into the container's backup volume
docker cp "$TEMP_DIR/database.sql.gz" "${CONTAINER_NAME}:/home/frappe/backups/"

if [ -f "$TEMP_DIR/private-files.tar" ]; then
    docker cp "$TEMP_DIR/private-files.tar" "${CONTAINER_NAME}:/home/frappe/backups/"
fi

if [ -f "$TEMP_DIR/public-files.tar" ]; then
    docker cp "$TEMP_DIR/public-files.tar" "${CONTAINER_NAME}:/home/frappe/backups/"
fi

echo ""
echo "=========================================="
echo "Backup files loaded successfully!"
echo "=========================================="
echo ""
echo "Files are now in the container at /home/frappe/backups/"
echo ""
echo "To restore the backup, run:"
echo "  docker compose exec frappe bash /workspace/restore.sh"
echo ""

#!/bin/bash
# Docker Hub Configuration
DOCKER_HUB_USERNAME="username" # điền username
DOCKER_HUB_PASSWORD="userpassword"  # điền password
DOCKER_HUB_REPO="username/gitlab-backup" #Điền tên repository (vd: username/gitlab-backup)

# GitLab directories
GITLAB_CONFIG="/etc/gitlab"
GITLAB_BACKUP_DIR="/var/opt/gitlab/backups"
TEMP_DIR="/tmp/gitlab_restore_$$"
ZIP_BACKUP_DIR="/var/backups/gitlab-zips"   # Thư mục lưu file zip backup

ensure_docker_installed() {
    echo "[INFO] Checking Docker installation..."
    if ! command -v docker > /dev/null; then
        echo "[INFO] Docker not found. Installing Docker..."
        sudo apt-get update
        sudo apt-get install -y docker.io
        echo "[INFO] Docker installation completed"
    else
        echo "[INFO] Docker is already installed"
    fi
}

list_backups() {
    ensure_docker_installed
    echo "[INFO] Available backups on Docker Hub:"
    if ! echo "$DOCKER_HUB_PASSWORD" | docker login -u "$DOCKER_HUB_USERNAME" --password-stdin; then
        echo "[ERROR] Failed to login to Docker Hub"
        exit 1
    fi
    docker images "$DOCKER_HUB_REPO" --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}"
}

restore_from_zip() {
    local tag=$1
    local zip_file="$ZIP_BACKUP_DIR/gitlab_backup_${tag}.zip"
    if [ ! -f "$zip_file" ]; then
        echo "[ERROR] Zip file not found: $zip_file"
        exit 1
    fi

    echo "[INFO] Found local zip backup: $zip_file"
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"
    echo "[INFO] Extracting zip file..."
    unzip -q "$zip_file" -d "$TEMP_DIR"

    # Find backup file
    local backup_file=$(find "$TEMP_DIR/backup" -name "*_gitlab_backup.tar" -type f)
    if [ -z "$backup_file" ]; then
        rm -rf "$TEMP_DIR"
        echo "[ERROR] Backup file not found in zip"
        exit 1
    fi

    # Create backup directory if it doesn't exist
    mkdir -p "$GITLAB_BACKUP_DIR"

    # Copy backup file to GitLab backup directory
    echo "[INFO] Copying backup file to GitLab backup directory..."
    cp "$backup_file" "$GITLAB_BACKUP_DIR/"
    chown git:git "$GITLAB_BACKUP_DIR"/*_gitlab_backup.tar

    # Backup existing config files
    if [ -f "$GITLAB_CONFIG/gitlab.rb" ]; then
        mv "$GITLAB_CONFIG/gitlab.rb" "$GITLAB_CONFIG/gitlab.rb.$(date +%Y%m%d_%H%M%S).bak"
    fi
    if [ -f "$GITLAB_CONFIG/gitlab-secrets.json" ]; then
        mv "$GITLAB_CONFIG/gitlab-secrets.json" "$GITLAB_CONFIG/gitlab-secrets.json.$(date +%Y%m%d_%H%M%S).bak"
    fi

    # Copy configuration files
    echo "[INFO] Restoring configuration files..."
    cp "$TEMP_DIR/backup/gitlab.rb" "$GITLAB_CONFIG/"
    cp "$TEMP_DIR/backup/gitlab-secrets.json" "$GITLAB_CONFIG/"
    chmod 600 "$GITLAB_CONFIG/gitlab-secrets.json"

    # Reconfigure GitLab
    echo "[INFO] Reconfiguring GitLab..."
    gitlab-ctl reconfigure

    # Stop GitLab services before restore
    echo "[INFO] Stopping GitLab services..."
    gitlab-ctl stop puma
    gitlab-ctl stop sidekiq
    sleep 10

    # Restore from backup
    echo "[INFO] Starting restore process..."
    local backup_timestamp=$(basename "$backup_file" _gitlab_backup.tar)
    if ! gitlab-backup restore BACKUP="$backup_timestamp" force=yes; then
        echo "[ERROR] Failed to restore from backup"
        exit 1
    fi

    # Start GitLab
    echo "[INFO] Restore completed. Starting GitLab..."
    gitlab-ctl start
    sleep 30

    # Check GitLab status
    echo "[INFO] Checking GitLab status..."
    gitlab-ctl status

    # Cleanup
    echo "[INFO] Cleaning up..."
    rm -rf "$TEMP_DIR"

    echo "[INFO] Restore process completed successfully!"
    echo "[INFO] Please wait a few minutes for all services to start"
}

restore_from_docker() {
    local tag=$1
    ensure_docker_installed

    # Create temporary directory
    echo "[INFO] Creating temporary directory..."
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"

    # Login to Docker Hub
    echo "[INFO] Logging in to Docker Hub..."
    if ! echo "$DOCKER_HUB_PASSWORD" | docker login -u "$DOCKER_HUB_USERNAME" --password-stdin; then
        echo "[ERROR] Failed to login to Docker Hub"
        exit 1
    fi

    # Pull backup image
    echo "[INFO] Pulling backup image: $DOCKER_HUB_REPO:$tag"
    if ! docker pull "$DOCKER_HUB_REPO:$tag"; then
        echo "[ERROR] Failed to pull backup image"
        exit 1
    fi

    # Extract backup files
    echo "[INFO] Extracting backup files..."
    local container_id=$(docker create "$DOCKER_HUB_REPO:$tag")
    if [ -z "$container_id" ]; then
        echo "[ERROR] Failed to create temporary container"
        exit 1
    fi

    docker cp "$container_id:/backup/." "$TEMP_DIR/"
    docker rm "$container_id"

    # Find backup file
    local backup_file=$(find "$TEMP_DIR" -name "*_gitlab_backup.tar" -type f)
    if [ -z "$backup_file" ]; then
        rm -rf "$TEMP_DIR"
        echo "[ERROR] Backup file not found in image"
        exit 1
    fi

    # Create backup directory if it doesn't exist
    mkdir -p "$GITLAB_BACKUP_DIR"

    # Copy backup file to GitLab backup directory
    echo "[INFO] Copying backup file to GitLab backup directory..."
    cp "$backup_file" "$GITLAB_BACKUP_DIR/"
    chown git:git "$GITLAB_BACKUP_DIR"/*_gitlab_backup.tar

    # Backup existing config files
    if [ -f "$GITLAB_CONFIG/gitlab.rb" ]; then
        mv "$GITLAB_CONFIG/gitlab.rb" "$GITLAB_CONFIG/gitlab.rb.$(date +%Y%m%d_%H%M%S).bak"
    fi
    if [ -f "$GITLAB_CONFIG/gitlab-secrets.json" ]; then
        mv "$GITLAB_CONFIG/gitlab-secrets.json" "$GITLAB_CONFIG/gitlab-secrets.json.$(date +%Y%m%d_%H%M%S).bak"
    fi

    # Copy configuration files
    echo "[INFO] Restoring configuration files..."
    cp "$TEMP_DIR/gitlab.rb" "$GITLAB_CONFIG/"
    cp "$TEMP_DIR/gitlab-secrets.json" "$GITLAB_CONFIG/"
    chmod 600 "$GITLAB_CONFIG/gitlab-secrets.json"

    # Reconfigure GitLab
    echo "[INFO] Reconfiguring GitLab..."
    gitlab-ctl reconfigure

    # Stop GitLab services before restore
    echo "[INFO] Stopping GitLab services..."
    gitlab-ctl stop puma
    gitlab-ctl stop sidekiq
    sleep 10

    # Restore from backup
    echo "[INFO] Starting restore process..."
    local backup_timestamp=$(basename "$backup_file" _gitlab_backup.tar)
    if ! gitlab-backup restore BACKUP="$backup_timestamp" force=yes; then
        echo "[ERROR] Failed to restore from backup"
        exit 1
    fi

    # Start GitLab
    echo "[INFO] Restore completed. Starting GitLab..."
    gitlab-ctl start
    sleep 30

    # Check GitLab status
    echo "[INFO] Checking GitLab status..."
    gitlab-ctl status

    # Cleanup
    echo "[INFO] Cleaning up..."
    rm -rf "$TEMP_DIR"

    echo "[INFO] Restore process completed successfully!"
    echo "[INFO] Please wait a few minutes for all services to start"
}

restore_backup() {
    local tag=$1
    if [ -z "$tag" ]; then
        echo "[ERROR] Please specify a backup tag to restore"
        exit 1
    fi

    # Thử restore từ file zip trước, nếu không có thì từ Docker Hub
    if [ -f "$ZIP_BACKUP_DIR/gitlab_backup_${tag}.zip" ]; then
        restore_from_zip "$tag"
    else
        echo "[INFO] No local zip found for tag $tag, restoring from Docker Hub..."
        restore_from_docker "$tag"
    fi
}

case "$1" in
    restore-zip)
        if [ -z "$2" ]; then
            echo "Error: Backup tag is required"
            echo "Usage: $0 restore-zip <backup_tag>"
            exit 1
        fi
        restore_from_zip "$2"
        ;;
    restore-docker)
        if [ -z "$2" ]; then
            echo "Error: Backup tag is required"
            echo "Usage: $0 restore-docker <backup_tag>"
            exit 1
        fi
        restore_from_docker "$2"
        ;;
    restore)
        if [ -z "$2" ]; then
            echo "Error: Backup tag is required"
            echo "Usage: $0 restore <backup_tag>"
            exit 1
        fi
        restore_backup "$2"
        ;;
    list)
        list_backups
        ;;
    *)
        echo "Usage: $0 {restore|restore-zip|restore-docker|list} [backup_tag]"
        echo "Commands:"
        echo "  restore <tag>         Restore from zip if exists, else from Docker Hub"
        echo "  restore-zip <tag>     Restore only from local zip"
        echo "  restore-docker <tag>  Restore only from Docker Hub"
        echo "  list                  List all available backups on Docker Hub"
        echo ""
        echo "Examples:"
        echo "  $0 list"
        echo "  $0 restore 20250413_154926"
        echo "  $0 restore-zip 20250413_154926"
        echo "  $0 restore-docker 20250413_154926"
        exit 1
        ;;
esac
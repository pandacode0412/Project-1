#!/bin/bash
# Docker Hub 
DOCKER_HUB_USERNAME="username" # điền username
DOCKER_HUB_PASSWORD="userpassword"  # điền password
DOCKER_HUB_REPO="username/gitlab-backup" #Điền tên repository (vd: username/gitlab-backup)

# GitLab directories
GITLAB_CONFIG="/etc/gitlab"
GITLAB_BACKUP_DIR="/var/opt/gitlab/backups"
TEMP_DIR="/tmp/gitlab_backup_$$"
ZIP_BACKUP_DIR="/var/backups/gitlab-zips"   # Thư mục lưu file zip backup

ensure_rsync() {
    echo "[INFO] Checking rsync installation..."
    if ! command -v rsync > /dev/null; then
        echo "[INFO] rsync not found. Installing rsync..."
        if ! sudo apt-get update; then
            echo "[ERROR] Failed to update package list"
            exit 1
        fi
        if ! sudo apt-get install -y rsync; then
            echo "[ERROR] Failed to install rsync"
            exit 1
        fi
        echo "[INFO] rsync installed successfully"
    else
        echo "[INFO] rsync is already installed"
    fi
}

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

# List backups
list_backups() {
    echo "[INFO] Available backups on Docker Hub:"
    if ! echo "$DOCKER_HUB_PASSWORD" | docker login -u "$DOCKER_HUB_USERNAME" --password-stdin; then
        echo "[ERROR] Failed to login to Docker Hub"
        exit 1
    fi
    docker images "$DOCKER_HUB_REPO" --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}"
}

# Create backup
create_backup() {
    ensure_rsync
    ensure_docker_installed

    # Create timestamp
    local timestamp=$(date +%Y%m%d_%H%M%S)
    echo "[INFO] Starting backup with timestamp: $timestamp"

    # Đảm bảo thư mục lưu file zip tồn tại
    mkdir -p "$ZIP_BACKUP_DIR"

    # Create temporary directory
    echo "[INFO] Creating temporary directory..."
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR/backup"

    # Create GitLab backup
    echo "[INFO] Creating GitLab backup..."
    if ! gitlab-backup create STRATEGY=copy; then
        rm -rf "$TEMP_DIR"
        echo "[ERROR] Failed to create GitLab backup"
        exit 1
    fi

    # Find the latest backup file
    local backup_file=$(find "$GITLAB_BACKUP_DIR" -name "*_gitlab_backup.tar" -type f -printf '%T@ %p\n' | sort -n | tail -1 | cut -f2- -d" ")
    if [ -z "$backup_file" ]; then
        rm -rf "$TEMP_DIR"
        echo "[ERROR] No backup file found"
        exit 1
    fi

    # Copy backup files
    echo "[INFO] Copying backup files..."
    cp "$backup_file" "$TEMP_DIR/backup/"
    cp "$GITLAB_CONFIG/gitlab.rb" "$TEMP_DIR/backup/"
    cp "$GITLAB_CONFIG/gitlab-secrets.json" "$TEMP_DIR/backup/"

    # Nén thành file zip và lưu vào thư mục chỉ định
    ZIP_FILE="$ZIP_BACKUP_DIR/gitlab_backup_$timestamp.zip"
    echo "[INFO] Compressing backup files into zip: $ZIP_FILE"
    cd "$TEMP_DIR"
    zip -r "$ZIP_FILE" backup
    cd - > /dev/null

    # Create Dockerfile
    echo "[INFO] Creating Dockerfile..."
    cat > "$TEMP_DIR/Dockerfile" << EOF
FROM alpine:latest
COPY backup /backup
RUN chmod 600 /backup/gitlab-secrets.json
EOF

    # Login to Docker Hub
    echo "[INFO] Logging in to Docker Hub..."
    if ! echo "$DOCKER_HUB_PASSWORD" | docker login -u "$DOCKER_HUB_USERNAME" --password-stdin; then
        rm -rf "$TEMP_DIR"
        echo "[ERROR] Failed to login to Docker Hub"
        exit 1
    fi

    # Build Docker image
    echo "[INFO] Building Docker image..."
    if ! docker build -t "$DOCKER_HUB_REPO:$timestamp" "$TEMP_DIR"; then
        rm -rf "$TEMP_DIR"
        echo "[ERROR] Failed to build Docker image"
        exit 1
    fi

    # Push to Docker Hub
    echo "[INFO] Pushing backup to Docker Hub..."
    if ! docker push "$DOCKER_HUB_REPO:$timestamp"; then
        rm -rf "$TEMP_DIR"
        echo "[ERROR] Failed to push backup to Docker Hub"
        exit 1
    fi

    # Cleanup old backups (older than 7 days)
    echo "[INFO] Cleaning up old backups..."
    # Clean local backup files (chỉ xóa file tar, không xóa file zip)
    find "$GITLAB_BACKUP_DIR" -name "*_gitlab_backup.tar" -mtime +7 -delete

    # Clean old Docker images
    docker images "$DOCKER_HUB_REPO" --format "{{.Repository}}:{{.Tag}}" | while read -r image; do
        creation_date=$(docker image inspect "$image" --format '{{.Created}}')
        creation_timestamp=$(date -d "$creation_date" +%s)
        current_timestamp=$(date +%s)
        days_old=$(( (current_timestamp - creation_timestamp) / 86400 ))
        if [ "$days_old" -gt 7 ]; then
            echo "[INFO] Removing old backup image: $image"
            docker rmi "$image" || true
        fi
    done

    # Cleanup temporary files
    echo "[INFO] Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"

    echo "[INFO] Backup completed successfully!"
    echo "[INFO] Backup tag: $timestamp"
    echo "[INFO] Backup zip file: $ZIP_FILE"
}

case "$1" in
    backup)
        create_backup
        ;;
    list)
        list_backups
        ;;
    *)
        echo "Usage: $0 {backup|list}"
        echo "Commands:"
        echo "  backup    Create a new backup"
        echo "  list      List all available backups"
        echo ""
        echo "Examples:"
        echo "  $0 backup"
        echo "  $0 list"
        exit 1
        ;;
esac
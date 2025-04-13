#!/bin/bash
# Docker Hub Configuration
DOCKER_HUB_USERNAME="ap0412" # điền username
DOCKER_HUB_PASSWORD=""  # điền password
DOCKER_HUB_REPO="ap0412/gitlab-backup" #Điền tên repository (vd: username/gitlab-backup)

# GitLab directories
GITLAB_CONFIG="/etc/gitlab"
GITLAB_BACKUP_DIR="/var/opt/gitlab/backups"
TEMP_DIR="/tmp/gitlab_restore_$$"


ensure_docker_installed() {
    print_message "Checking Docker installation..."
    
    if ! command -v docker > /dev/null; then
        print_message "Docker not found. Installing Docker..."
        
        # Install Docker using convenience script
        apt install docker.io -y
      
        
        print_message "Docker installation completed"
    else
        print_message "Docker is already installed"
    fi
}

list_backups() {
    ensure_docker_installed
    print_message "Available backups on Docker Hub:"
    if ! echo "$DOCKER_HUB_PASSWORD" | docker login -u "$DOCKER_HUB_USERNAME" --password-stdin; then
        print_error "Failed to login to Docker Hub"
    fi
    docker images "$DOCKER_HUB_REPO" --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}"
}

restore_backup() {
    local tag=$1
    if [ -z "$tag" ]; then
        print_error "Please specify a backup tag to restore"
    fi

    ensure_docker_installed

    # Create temporary directory
    print_message "Creating temporary directory..."
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"

    # Login to Docker Hub
    print_message "Logging in to Docker Hub..."
    if ! echo "$DOCKER_HUB_PASSWORD" | docker login -u "$DOCKER_HUB_USERNAME" --password-stdin; then
        print_error "Failed to login to Docker Hub"
    fi

    # Pull backup image
    print_message "Pulling backup image: $DOCKER_HUB_REPO:$tag"
    if ! docker pull "$DOCKER_HUB_REPO:$tag"; then
        print_error "Failed to pull backup image"
    fi

    # Extract backup files
    print_message "Extracting backup files..."
    local container_id=$(docker create "$DOCKER_HUB_REPO:$tag")
    if [ -z "$container_id" ]; then
        print_error "Failed to create temporary container"
    fi

    docker cp "$container_id:/backup/." "$TEMP_DIR/"
    docker rm "$container_id"

    # Find backup file
    local backup_file=$(find "$TEMP_DIR" -name "*_gitlab_backup.tar" -type f)
    if [ -z "$backup_file" ]; then
        rm -rf "$TEMP_DIR"
        print_error "Backup file not found in image"
    fi

    # Create backup directory if it doesn't exist
    mkdir -p "$GITLAB_BACKUP_DIR"

    # Copy backup file to GitLab backup directory
    print_message "Copying backup file to GitLab backup directory..."
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
    print_message "Restoring configuration files..."
    cp "$TEMP_DIR/gitlab.rb" "$GITLAB_CONFIG/"
    cp "$TEMP_DIR/gitlab-secrets.json" "$GITLAB_CONFIG/"
    chmod 600 "$GITLAB_CONFIG/gitlab-secrets.json"

    # Reconfigure GitLab
    print_message "Reconfiguring GitLab..."
    gitlab-ctl reconfigure

    # Stop GitLab services before restore
    print_message "Stopping GitLab services..."
    gitlab-ctl stop puma
    gitlab-ctl stop sidekiq
    sleep 10

    # Restore from backup
    print_message "Starting restore process..."
    local backup_timestamp=$(basename "$backup_file" _gitlab_backup.tar)
    
    if ! gitlab-backup restore BACKUP="$backup_timestamp" force=yes; then
        print_error "Failed to restore from backup"
    fi

    # Start GitLab
    print_message "Restore completed. Starting GitLab..."
    gitlab-ctl start
    sleep 30

    # Check GitLab status
    print_message "Checking GitLab status..."
    gitlab-ctl status

    # Cleanup
    print_message "Cleaning up..."
    rm -rf "$TEMP_DIR"

    print_message "Restore process completed successfully!"
    print_message "Please wait a few minutes for all services to start"
}

case "$1" in
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
        echo "Usage: $0 {restore|list} [backup_tag]"
        echo "Commands:"
        echo "  list              List all available backups"
        echo "  restore <tag>     Restore from specified backup"
        echo ""
        echo "Examples:"
        echo "  $0 list"
        echo "  $0 restore 20250413_154926"
        exit 1
        ;;
esac
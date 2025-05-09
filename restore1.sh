#!/bin/bash
# Docker Hub Configuration
DOCKER_HUB_USERNAME="username" # điền username
DOCKER_HUB_PASSWORD="userpassword"  # điền password
DOCKER_HUB_REPO="username/gitlab-backup" #Điền tên repository (vd: username/gitlab-backup)

# GitLab directories
GITLAB_CONFIG="/etc/gitlab"
GITLAB_BACKUP_DIR="/var/opt/gitlab/backups"
TEMP_DIR="/tmp/gitlab_restore_$$"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Print functions
print_message() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

print_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

# Check if running as root
check_root() {
    if [ "$(id -u)" != "0" ]; then
        print_error "This script must be run as root"
    fi
}

# Check GitLab installation
check_gitlab() {
    if ! command -v gitlab-ctl > /dev/null; then
        print_error "GitLab is not installed"
    fi
}

# Backup existing configuration
backup_config() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    if [ -f "$GITLAB_CONFIG/gitlab.rb" ]; then
        print_message "Backing up gitlab.rb..."
        cp "$GITLAB_CONFIG/gitlab.rb" "$GITLAB_CONFIG/gitlab.rb.$timestamp.bak"
    fi
    
    if [ -f "$GITLAB_CONFIG/gitlab-secrets.json" ]; then
        print_message "Backing up gitlab-secrets.json..."
        cp "$GITLAB_CONFIG/gitlab-secrets.json" "$GITLAB_CONFIG/gitlab-secrets.json.$timestamp.bak"
    fi
}

# Stop GitLab services
stop_gitlab_services() {
    print_message "Stopping GitLab services..."
    gitlab-ctl stop puma
    gitlab-ctl stop sidekiq
    sleep 10
}

# Start GitLab services
start_gitlab_services() {
    print_message "Starting GitLab services..."
    gitlab-ctl start
    sleep 30
}

# Restore from local backup
restore_from_local() {
    local backup_file=$1
    
    # Validate input
    if [ -z "$backup_file" ]; then
        print_error "Please specify a backup file path"
    fi
    
    # Check if file exists in current directory
    if [ ! -f "$backup_file" ]; then
        # Check if file exists in backup directory
        if [ -f "$GITLAB_BACKUP_DIR/$backup_file" ]; then
            backup_file="$GITLAB_BACKUP_DIR/$backup_file"
        else
            print_error "Backup file not found: $backup_file\nPlease make sure the file exists in current directory or in $GITLAB_BACKUP_DIR"
        fi
    fi
    
    # Check file permissions
    if [ ! -r "$backup_file" ]; then
        print_error "Cannot read backup file: $backup_file\nPlease check file permissions"
    fi
    
    print_message "Found backup file: $backup_file"
    
    # Check prerequisites
    check_root
    check_gitlab
    
    # Create temporary directory
    print_message "Creating temporary directory..."
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"
    
    # Copy backup file
    print_message "Copying backup file..."
    cp "$backup_file" "$TEMP_DIR/"
    
    # Create backup directory if needed
    mkdir -p "$GITLAB_BACKUP_DIR"
    
    # Copy to GitLab backup directory
    print_message "Moving backup to GitLab backup directory..."
    cp "$backup_file" "$GITLAB_BACKUP_DIR/"
    chown git:git "$GITLAB_BACKUP_DIR"/*_gitlab_backup.tar
    
    # Backup existing config
    backup_config
    
    # Copy configuration files if they exist
    if [ -f "$TEMP_DIR/gitlab.rb" ]; then
        print_message "Restoring gitlab.rb..."
        cp "$TEMP_DIR/gitlab.rb" "$GITLAB_CONFIG/"
    fi
    
    if [ -f "$TEMP_DIR/gitlab-secrets.json" ]; then
        print_message "Restoring gitlab-secrets.json..."
        cp "$TEMP_DIR/gitlab-secrets.json" "$GITLAB_CONFIG/"
        chmod 600 "$GITLAB_CONFIG/gitlab-secrets.json"
    fi
    
    # Reconfigure GitLab
    print_message "Reconfiguring GitLab..."
    gitlab-ctl reconfigure
    
    # Stop services before restore
    stop_gitlab_services
    
    # Get backup timestamp
    local backup_timestamp=$(basename "$backup_file" _gitlab_backup.tar)
    
    # Perform restore
    print_message "Starting restore process..."
    if ! gitlab-backup restore BACKUP="$backup_timestamp" force=yes; then
        print_error "Failed to restore from backup"
    fi
    
    # Start services
    start_gitlab_services
    
    # Check status
    print_message "Checking GitLab status..."
    gitlab-ctl status
    
    # Cleanup
    print_message "Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"
    
    print_message "Restore completed successfully!"
    print_message "Please wait a few minutes for all services to start"
}

# Restore from Docker Hub
restore_from_docker() {
    local tag=$1
    
    # Validate input
    if [ -z "$tag" ]; then
        print_error "Please specify a backup tag"
    fi
    
    # Check prerequisites
    check_root
    check_gitlab
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
    
    # Create backup directory if needed
    mkdir -p "$GITLAB_BACKUP_DIR"
    
    # Copy to GitLab backup directory
    print_message "Moving backup to GitLab backup directory..."
    cp "$backup_file" "$GITLAB_BACKUP_DIR/"
    chown git:git "$GITLAB_BACKUP_DIR"/*_gitlab_backup.tar
    
    # Backup existing config
    backup_config
    
    # Copy configuration files
    if [ -f "$TEMP_DIR/gitlab.rb" ]; then
        print_message "Restoring gitlab.rb..."
        cp "$TEMP_DIR/gitlab.rb" "$GITLAB_CONFIG/"
    fi
    
    if [ -f "$TEMP_DIR/gitlab-secrets.json" ]; then
        print_message "Restoring gitlab-secrets.json..."
        cp "$TEMP_DIR/gitlab-secrets.json" "$GITLAB_CONFIG/"
        chmod 600 "$GITLAB_CONFIG/gitlab-secrets.json"
    fi
    
    # Reconfigure GitLab
    print_message "Reconfiguring GitLab..."
    gitlab-ctl reconfigure
    
    # Stop services before restore
    stop_gitlab_services
    
    # Get backup timestamp
    local backup_timestamp=$(basename "$backup_file" _gitlab_backup.tar)
    
    # Perform restore
    print_message "Starting restore process..."
    if ! gitlab-backup restore BACKUP="$backup_timestamp" force=yes; then
        print_error "Failed to restore from backup"
    fi
    
    # Start services
    start_gitlab_services
    
    # Check status
    print_message "Checking GitLab status..."
    gitlab-ctl status
    
    # Cleanup
    print_message "Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"
    
    print_message "Restore completed successfully!"
    print_message "Please wait a few minutes for all services to start"
}

case "$1" in
    restore-docker)
        if [ -z "$2" ]; then
            echo "Error: Docker image tag is required"
            echo "Usage: $0 restore-docker <image_tag>"
            exit 1
        fi
        restore_from_docker "$2"
        ;;
    restore-local)
        if [ -z "$2" ]; then
            echo "Error: Backup file is required"
            echo "Usage: $0 restore-local <backup_file>"
            exit 1
        fi
        restore_from_local "$2"
        ;;
    list)
        list_backups
        ;;
    *)
        echo "Usage: $0 {restore-docker|restore-local|list}"
        echo "Commands:"
        echo "  restore-docker <image_tag>    Restore from Docker image"
        echo "  restore-local <backup_file>   Restore from local backup file"
        echo "  list                          List available backups on Docker Hub"
        echo ""
        echo "Examples:"
        echo "  $0 list"
        echo "  $0 restore-docker 20250413_154926"
        echo "  $0 restore-local 1746801710_2025_05_09_14.9.1-ee_gitlab_backup.tar"
        exit 1
        ;;
esac 
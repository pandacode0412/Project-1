#!/bin/bash
# Docker Hub 
DOCKER_HUB_USERNAME="username" # điền username
DOCKER_HUB_PASSWORD="userpassword"  # điền password
DOCKER_HUB_REPO="username/gitlab-backup" #Điền tên repository (vd: username/gitlab-backup)

# GitLab directories
GITLAB_CONFIG="/etc/gitlab"
GITLAB_BACKUP_DIR="/var/opt/gitlab/backups"
TEMP_DIR="/tmp/gitlab_backup_$$"


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



ensure_rsync() {
    print_message "Checking rsync installation..."
    if ! command -v rsync > /dev/null; then
        print_message "rsync not found. Installing rsync..."
        if ! sudo apt-get update; then
            print_error "Failed to update package list"
        fi
        if ! sudo apt-get install -y rsync; then
            print_error "Failed to install rsync"
        fi
        print_message "rsync installed successfully"
    else
        print_message "rsync is already installed"
    fi
}


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

# List backups
list_backups() {
    print_message "Available backups on Docker Hub:"
    if ! echo "$DOCKER_HUB_PASSWORD" | docker login -u "$DOCKER_HUB_USERNAME" --password-stdin; then
        print_error "Failed to login to Docker Hub"
    fi
    docker images "$DOCKER_HUB_REPO" --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}"
}

# Create backup
create_backup() {
    
   ensure_rsync
   ensure_docker_installed

    # Create timestamp
    local timestamp=$(date +%Y%m%d_%H%M%S)
    print_message "Starting backup with timestamp: $timestamp"

    # Create temporary directory
    print_message "Creating temporary directory..."
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR/backup"

    # Create GitLab backup
    print_message "Creating GitLab backup..."
    if ! gitlab-backup create STRATEGY=copy; then
        rm -rf "$TEMP_DIR"
        print_error "Failed to create GitLab backup"
    fi

    # Find the latest backup file
    local backup_file=$(find "$GITLAB_BACKUP_DIR" -name "*_gitlab_backup.tar" -type f -printf '%T@ %p\n' | sort -n | tail -1 | cut -f2- -d" ")
    if [ -z "$backup_file" ]; then
        rm -rf "$TEMP_DIR"
        print_error "No backup file found"
    fi

    # Copy backup files
    print_message "Copying backup files..."
    cp "$backup_file" "$TEMP_DIR/backup/"
    cp "$GITLAB_CONFIG/gitlab.rb" "$TEMP_DIR/backup/"
    cp "$GITLAB_CONFIG/gitlab-secrets.json" "$TEMP_DIR/backup/"

    # Create Dockerfile
    print_message "Creating Dockerfile..."
    cat > "$TEMP_DIR/Dockerfile" << EOF
FROM alpine:latest
COPY backup /backup
RUN chmod 600 /backup/gitlab-secrets.json
EOF

    # Login to Docker Hub
    print_message "Logging in to Docker Hub..."
    if ! echo "$DOCKER_HUB_PASSWORD" | docker login -u "$DOCKER_HUB_USERNAME" --password-stdin; then
        rm -rf "$TEMP_DIR"
        print_error "Failed to login to Docker Hub"
    fi

    # Build Docker image
    print_message "Building Docker image..."
    if ! docker build -t "$DOCKER_HUB_REPO:$timestamp" "$TEMP_DIR"; then
        rm -rf "$TEMP_DIR"
        print_error "Failed to build Docker image"
    fi

    # Push to Docker Hub
    print_message "Pushing backup to Docker Hub..."
    if ! docker push "$DOCKER_HUB_REPO:$timestamp"; then
        rm -rf "$TEMP_DIR"
        print_error "Failed to push backup to Docker Hub"
    fi

    # Cleanup old backups (older than 7 days)
    print_message "Cleaning up old backups..."
    
    # Clean local backup files
    find "$GITLAB_BACKUP_DIR" -name "*_gitlab_backup.tar" -mtime +7 -delete

    # Clean old Docker images
    docker images "$DOCKER_HUB_REPO" --format "{{.Repository}}:{{.Tag}}" | while read -r image; do
        creation_date=$(docker image inspect "$image" --format '{{.Created}}')
        creation_timestamp=$(date -d "$creation_date" +%s)
        current_timestamp=$(date +%s)
        days_old=$(( (current_timestamp - creation_timestamp) / 86400 ))
        
        if [ "$days_old" -gt 7 ]; then
            print_message "Removing old backup image: $image"
            docker rmi "$image" || true
        fi
    done

    # Cleanup temporary files
    print_message "Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"

    print_message "Backup completed successfully!"
    print_message "Backup tag: $timestamp"
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
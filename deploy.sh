#!/bin/bash -x

# Exit on error, unset variables, and pipe failures
set -euo pipefail

# Logging setup
LOG_FILE="deploy_$(date +%Y%m%d).log"
echo "Deployment started at $(date)" >> "$LOG_FILE"

# Trap errors
trap 'echo "ERROR: Deployment failed at $(date) with exit code $?" >> "$LOG_FILE"; exit 1' ERR

# Log function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Check status function
check_status() {
    if [ $? -ne 0 ]; then
        log "ERROR: $1 failed"
        exit 1
    fi
    log "SUCCESS: $1 completed"
}

CLEANUP=false
if [ "${1:-}" = "--cleanup" ]; then
    CLEANUP=true
    shift
fi

# 1. Collect User Inputs
read -p "Enter Git Repository URL: " REPO_URL
read -p "Enter Personal Access Token: " PAT
read -p "Enter Branch name (default: main): " BRANCH
BRANCH=${BRANCH:-main}
read -p "Enter Remote Server Username: " SSH_USER
read -p "Enter Server IP Address: " SERVER_IP
read -p "Enter SSH Key Path: " SSH_KEY
read -p "Enter Application Port: " APP_PORT

if [ -z "$REPO_URL" ] || [ -z "$PAT" ] || [ -z "$SSH_USER" ] || [ -z "$SERVER_IP" ] || [ -z "$SSH_KEY" ] || [ -z "$APP_PORT" ]; then
    log "ERROR: All fields are required"
    exit 1
fi
if ! echo "$APP_PORT" | grep -qE '^[0-9]+$'; then
    log "ERROR: Port must be a number"
    exit 1
fi

log "Cloning or updating repository $REPO_URL"
if [ -d "repo" ]; then
    cd repo
    git pull origin "$BRANCH"
else
    git clone "https://$PAT@$(echo $REPO_URL | sed 's/https:\/\///')" repo
    cd repo
fi
git checkout "$BRANCH"
check_status "Repository cloning/pulling"

log "Cloning or updating repository $REPO_URL"
if [ -d "repo" ]; then
    cd repo
    git pull origin "$BRANCH"
else
    git clone "https://$PAT@$(echo $REPO_URL | sed 's/https:\/\///')" repo
    cd repo
fi
git checkout "$BRANCH"
check_status "Repository cloning/pulling"

log "Navigating to project directory"
if [ -f "Dockerfile" ] || [ -f "docker-compose.yml" ]; then
    log "Found Dockerfile or docker-compose.yml"
else
    log "ERROR: No Dockerfile or docker-compose.yml found"
    exit 1
fi

# 3. SSH Connectivity
log "Testing SSH connectivity to $SSH_USER@$SERVER_IP"
ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 "$SSH_USER@$SERVER_IP" "echo Connection successful" || {
    log "ERROR: SSH connectivity failed"
    exit 1
}

# 4. Server Preparation
log "Preparing remote environment on $SERVER_IP"
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" << 'EOF'
    sudo dnf update -y || sudo apt update -y && sudo apt upgrade -y
    if ! command -v docker &> /dev/null; then
        sudo apt install docker.io -y || sudo dnf install docker -y
        sudo systemctl start docker
        sudo systemctl enable docker
    fi
    if ! command -v docker-compose &> /dev/null; then
        sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
    fi
    sudo usermod -aG docker "$USER"
    if ! command -v nginx &> /dev/null; then
        sudo apt install nginx -y || sudo dnf install nginx -y
        sudo systemctl start nginx
        sudo systemctl enable nginx
    fi
    docker --version
    docker-compose --version
    nginx -v
EOF
check_status "Remote environment preparation"

# 5. Docker Deployment
log "Transferring project files to $SERVER_IP"
# Ensure the target directory exists on the remote server with proper permissions and ownership
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" "sudo mkdir -p /home/$SSH_USER/repo && sudo chmod 755 /home/$SSH_USER/repo && sudo chown $SSH_USER:$SSH_USER /home/$SSH_USER/repo" 2>> "$LOG_FILE" || {
    log "ERROR: Failed to create or configure remote directory /home/$SSH_USER/repo"
    exit 1
}
log "Remote directory /home/$SSH_USER/repo created and configured"
# Verify the directory is accessible
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" "[ -w /home/$SSH_USER/repo ]" 2>> "$LOG_FILE" || {
    log "ERROR: Remote directory /home/$SSH_USER/repo is not writable"
    exit 1
}
log "Verified remote directory /home/$SSH_USER/repo is writable"
# Transfer files with explicit error handling, verbose output, and detailed logging
scp -i "$SSH_KEY" -r -v . "$SSH_USER@$SERVER_IP:/home/$SSH_USER/repo" 2>> "$LOG_FILE" || {
    log "ERROR: Failed to transfer files to /home/$SSH_USER/repo. Check log for details: $(cat $LOG_FILE | tail -n 5)"
    exit 1
}
log "Files transferred to /home/$SSH_USER/repo"
check_status "File transfer"

log "Deploying application on $SERVER_IP"
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" << EOF
    cd /home/$SSH_USER/repo
    if [ -f "docker-compose.yml" ]; then
        docker-compose down --remove-orphans || true
        docker-compose up -d --build
    else
        docker stop myapp || true
        docker rm myapp || true
        docker build -t myapp .
        docker run -d --name myapp -p $APP_PORT:$APP_PORT myapp
    fi
    if [ "\$(docker ps -q -f name=myapp)" ]; then
        echo "Container is running"
    else
        echo "ERROR: Container failed to start"
        exit 1
    fi
EOF
check_status "Application deployment"

log "Configuring Nginx reverse proxy on $SERVER_IP"
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" << EOF
    sudo bash -c 'cat > /etc/nginx/conf.d/proxy.conf' << 'INNEREOF'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
INNEREOF
    sudo nginx -t
    if [ \$? -eq 0 ]; then
        sudo systemctl reload nginx
    else
        echo "ERROR: Nginx config test failed"
        exit 1
    fi
EOF
check_status "Nginx configuration"



log "Validating deployment on $SERVER_IP"
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" << 'EOF'
    if systemctl is-active --quiet docker; then
        echo "Docker service is running"
    else
        echo "ERROR: Docker service is not running"
        exit 1
    fi
    if [ "$(docker ps -q -f name=myapp)" ]; then
        echo "Container myapp is active"
    else
        echo "ERROR: Container myapp is not running"
        exit 1
    fi
    if curl -s -o /dev/null http://localhost; then
        echo "Nginx proxying works locally"
    else
        echo "ERROR: Nginx proxying failed locally"
        exit 1
    fi
EOF
check_status "Deployment validation"

if [ "$CLEANUP" = true ]; then
    log "Performing cleanup on $SERVER_IP"
    ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" << 'EOF'
        cd /home/$SSH_USER/repo || true
        docker-compose down --remove-orphans || true
        docker stop myapp || true
        docker rm myapp || true
        sudo rm -rf /home/$SSH_USER/repo
        sudo rm /etc/nginx/conf.d/proxy.conf || true
        sudo systemctl reload nginx
    EOF
    check_status "Cleanup completed"
fi

log "Deployment completed successfully at $(date)"





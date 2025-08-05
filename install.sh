#!/bin/bash

install_dokploy() {
    # Check if running as root
    if [ "$(id -u)" != "0" ]; then
        echo "This script must be run as root" >&2
        exit 1
    fi

    # Check if running on Linux (not macOS)
    if [ "$(uname)" = "Darwin" ]; then
        echo "This script must be run on Linux" >&2
        exit 1
    fi

    # Check if running inside a container
    if [ -f /.dockerenv ]; then
        echo "This script must be run on Linux" >&2
        exit 1
    fi

    # Check if something is running on port 80
    if ss -tulnp | grep ':80 ' >/dev/null; then
        echo "Error: something is already running on port 80" >&2
        exit 1
    fi

    # Check if something is running on port 443
    if ss -tulnp | grep ':443 ' >/dev/null; then
        echo "Error: something is already running on port 443" >&2
        exit 1
    fi

    # Function to check if a command exists
    command_exists() {
        command -v "$@" > /dev/null 2>&1
    }

    # Install git if not present
    if command_exists git; then
        echo "Git already installed"
    else
        echo "Installing Git..."
        apt-get update && apt-get install -y git
    fi

    # Install Docker if not present
    if command_exists docker; then
        echo "Docker already installed"
    else
        echo "Installing Docker..."
        curl -sSL https://get.docker.com | sh
    fi

    # Reset Docker Swarm
    docker swarm leave --force 2>/dev/null

    # Function to get server IP
    get_ip() {
        local ip=""
        
        # Try IPv4 first
        ip=$(curl -4s --connect-timeout 5 https://ifconfig.io 2>/dev/null)
        if [ -z "$ip" ]; then
            ip=$(curl -4s --connect-timeout 5 https://icanhazip.com 2>/dev/null)
        fi
        if [ -z "$ip" ]; then
            ip=$(curl -4s --connect-timeout 5 https://ipecho.net/plain 2>/dev/null)
        fi

        # Try IPv6 if no IPv4
        if [ -z "$ip" ]; then
            ip=$(curl -6s --connect-timeout 5 https://ifconfig.io 2>/dev/null)
            if [ -z "$ip" ]; then
                ip=$(curl -6s --connect-timeout 5 https://icanhazip.com 2>/dev/null)
            fi
            if [ -z "$ip" ]; then
                ip=$(curl -6s --connect-timeout 5 https://ipecho.net/plain 2>/dev/null)
            fi
        fi

        if [ -z "$ip" ]; then
            echo "Error: Could not determine server IP address automatically (neither IPv4 nor IPv6)." >&2
            echo "Please set the ADVERTISE_ADDR environment variable manually." >&2
            echo "Example: export ADVERTISE_ADDR=<your-server-ip>" >&2
            exit 1
        fi

        echo "$ip"
    }

    # Function to get private IP
    get_private_ip() {
        ip addr show | grep -E "inet (192\.168\.|10\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.)" | head -n1 | awk '{print $2}' | cut -d/ -f1
    }

    # Set advertise address
    advertise_addr="${ADVERTISE_ADDR:-$(get_private_ip)}"
    if [ -z "$advertise_addr" ]; then
        echo "ERROR: We couldn't find a private IP address."
        echo "Please set the ADVERTISE_ADDR environment variable manually."
        echo "Example: export ADVERTISE_ADDR=192.168.1.100"
        exit 1
    fi
    echo "Using advertise address: $advertise_addr"

    # Initialize Docker Swarm
    docker swarm init --advertise-addr $advertise_addr
    if [ $? -ne 0 ]; then
        echo "Error: Failed to initialize Docker Swarm" >&2
        exit 1
    fi
    echo "Swarm initialized"

    # Create Dokploy network
    docker network rm -f dokploy-network 2>/dev/null
    docker network create --driver overlay --attachable dokploy-network
    echo "Network created"

    # Create Dokploy directory
    mkdir -p /etc/dokploy
    chmod 777 /etc/dokploy

    # Clone Dokploy repository for custom development
    DOKPLOY_SRC_DIR="/tmp/dokploy"
    echo "Cloning Dokploy repository from https://github.com/HyHamza/dokploy..."
    rm -rf "$DOKPLOY_SRC_DIR"
    git clone --depth 1 https://github.com/HyHamza/dokploy.git "$DOKPLOY_SRC_DIR"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to clone Dokploy repository" >&2
        exit 1
    fi

    # Create .env.production file if it doesn't exist
    echo "Creating .env.production file..."
    cd "$DOKPLOY_SRC_DIR"
    if [ ! -f ".env.production" ]; then
cat << EOF > .env.production
NODE_ENV=production
DATABASE_URL=postgresql://dokploy:amukds4wi9001583845717ad2@dokploy-postgres:5432/dokploy
REDIS_URL=redis://dokploy-redis:6379
NEXTAUTH_SECRET=$(openssl rand -hex 32)
NEXTAUTH_URL=http://localhost:3000
GITHUB_CLIENT_ID=YOUR_GITHUB_CLIENT_ID
GITHUB_CLIENT_SECRET=YOUR_GITHUB_CLIENT_SECRET
EOF
        echo ".env.production file created"
    else
        echo ".env.production file already exists"
    fi

    # Check for Dockerfile and build the image
    if [ -f "$DOKPLOY_SRC_DIR/Dockerfile" ]; then
        echo "Building Dokploy Docker image from source..."
        docker build -t dokploy-local:latest "$DOKPLOY_SRC_DIR"
        if [ $? -ne 0 ]; then
            echo "Error: Failed to build Dokploy Docker image" >&2
            exit 1
        fi
    else
        echo "Error: No Dockerfile found in $DOKPLOY_SRC_DIR. Cannot build Dokploy image." >&2
        echo "Please ensure the repository contains a valid Dockerfile or provide a custom build process." >&2
        exit 1
    fi

    # Create basic Traefik configuration if not present in repository
    TRAEFIK_DIR="/etc/dokploy/traefik"
    mkdir -p "$TRAEFIK_DIR/dynamic"
    if [ ! -f "$TRAEFIK_DIR/traefik.yml" ]; then
        echo "Creating basic Traefik configuration..."
        cat << EOF > "$TRAEFIK_DIR/traefik.yml"
global:
  checkNewVersion: false
  sendAnonymousUsage: false

entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"

api:
  dashboard: true
  insecure: true

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
  file:
    directory: "/etc/dokploy/traefik/dynamic"
    watch: true
EOF
        chmod 644 "$TRAEFIK_DIR/traefik.yml"
    fi

    # Deploy PostgreSQL service
    docker service create \
        --name dokploy-postgres \
        --constraint 'node.role==manager' \
        --network dokploy-network \
        --env POSTGRES_USER=dokploy \
        --env POSTGRES_DB=dokploy \
        --env POSTGRES_PASSWORD=amukds4wi9001583845717ad2 \
        --mount type=volume,source=dokploy-postgres-database,target=/var/lib/postgresql/data \
        postgres:16

    # Deploy Redis service
    docker service create \
        --name dokploy-redis \
        --constraint 'node.role==manager' \
        --network dokploy-network \
        --mount type=volume,source=redis-data-volume,target=/data \
        redis:7

    # Deploy Dokploy service using the locally built image
    docker service create \
        --name dokploy \
        --replicas 1 \
        --network dokploy-network \
        --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
        --mount type=bind,source=/etc/dokploy,target=/etc/dokploy \
        --mount type=volume,source=dokploy-docker-config,target=/root/.docker \
        --publish published=3000,target=3000,mode=host \
        --update-parallelism 1 \
        --update-order stop-first \
        --constraint 'node.role==manager' \
        -e ADVERTISE_ADDR=$advertise_addr \
        dokploy-local:latest

    # Deploy Traefik service
    docker run -d \
        --name dokploy-traefik \
        --restart always \
        -v /etc/dokploy/traefik/traefik.yml:/etc/traefik/traefik.yml \
        -v /etc/dokploy/traefik/dynamic:/etc/traefik/dynamic \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -p 80:80/tcp \
        -p 443:443/tcp \
        -p 443:443/udp \
        traefik:v3.1.2

    docker network connect dokploy-network dokploy-traefik

    # Colors for output
    GREEN="\033[0;32m"
    YELLOW="\033[1;33m"
    BLUE="\033[0;34m"
    NC="\033[0m" # No Color

    # Function to format IP for URL
    format_ip_for_url() {
        local ip="$1"
        if echo "$ip" | grep -q ':'; then
            echo "[${ip}]"
        else
            echo "${ip}"
        fi
    }

    public_ip="${ADVERTISE_ADDR:-$(get_ip)}"
    formatted_addr=$(format_ip_for_url "$public_ip")
    echo ""
    printf "${GREEN}Congratulations, Dokploy is installed!${NC}\n"
    printf "${BLUE}Wait 15 seconds for the server to start${NC}\n"
    printf "${YELLOW}Please go to http://${formatted_addr}:3000${NC}\n"
    printf "${YELLOW}Dokploy source code is available at $DOKPLOY_SRC_DIR for custom development${NC}\n\n"
}

update_dokploy() {
    echo "Updating Dokploy from GitHub repository..."

    # Pull latest changes from GitHub
    DOKPLOY_SRC_DIR="/tmp/dokploy"
    if [ -d "$DOKPLOY_SRC_DIR" ]; then
        cd "$DOKPLOY_SRC_DIR"
        git pull origin main
        if [ $? -ne 0 ]; then
            echo "Error: Failed to pull latest changes from GitHub" >&2
            exit 1
        fi
    else
        echo "Error: Dokploy source directory ($DOKPLOY_SRC_DIR) not found. Please run install first." >&2
        exit 1
    fi

    # Create .env.production file if it doesn't exist after update
    if [ ! -f ".env.production" ]; then
        echo "Creating .env.production file after update..."
        cat << 'EOF' > .env.production
NODE_ENV=production
DATABASE_URL=postgresql://dokploy:amukds4wi9001583845717ad2@dokploy-postgres:5432/dokploy
REDIS_URL=redis://dokploy-redis:6379
NEXTAUTH_SECRET=your-secret-key-here
NEXTAUTH_URL=http://localhost:3000
EOF
        echo ".env.production file created"
    fi

    # Rebuild the Docker image
    if [ -f "$DOKPLOY_SRC_DIR/Dockerfile" ]; then
        echo "Rebuilding Dokploy Docker image..."
        docker build -t dokploy-local:latest "$DOKPLOY_SRC_DIR"
        if [ $? -ne 0 ]; then
            echo "Error: Failed to rebuild Dokploy Docker image" >&2
            exit 1
        fi
    else
        echo "Error: No Dockerfile found in $DOKPLOY_SRC_DIR. Cannot rebuild Dokploy image." >&2
        exit 1
    fi

    # Update the Dokploy service
    docker service update --image dokploy-local:latest dokploy
    if [ $? -ne 0 ]; then
        echo "Error: Failed to update Dokploy service" >&2
        exit 1
    fi

    echo "Dokploy has been updated to the latest version from GitHub."
}

# Main script execution
if [ "$1" = "update" ]; then
    update_dokploy
else
    install_dokploy
fi

#!/bin/bash

# ====================================================================
# MERGED SCRIPT: N8N Deployment with Pre-populated Data Download
# This script performs the following steps:
# 1. Installs Docker, Ngrok, Python (for venv), Unzip, and Git.
# 2. PROMPTS THE USER to select 'auto' (from file) or 'manual' (paste) GDrive URL.
# 3. Extracts the File ID.
# 4. Creates a Python virtual environment to install 'gdown'.
# 5. Downloads the n8n persistent data archive from Google Drive.
# 6. Extracts the data into the ./n8n-data host directory.
# 7. Configures the .env and docker-compose.yml files.
# 8. Starts the n8n Docker container.
# 9. Starts the Ngrok tunnel with a static domain in the background.
# ====================================================================

# --- 1. GLOBAL CONFIGURATION ---
# Configuration for Docker/Deployment
COMPOSE_FILE="docker-compose.yml"
ENV_FILE=".env"
N8N_INTERNAL_PORT="5678" # N8N container runs on 5678 internally

# ====================================================================
# 🔒 SECURE CONFIGURATION
# The script now reads your secrets from environment variables.
# These MUST be set before running the script using 'export' and 'sudo -E'.
#
# Example:
# export ENV_NGROK_DOMAIN="https://your.domain.com"
# export ENV_NGROK_TOKEN="your_token"
# sudo -E bash set2.sh start
# ====================================================================

# Read the domain from an environment variable passed at runtime
STATIC_NGROK_DOMAIN="${ENV_NGROK_DOMAIN}"

# Check if the variable is empty. If so, fail.
if [ -z "$STATIC_NGROK_DOMAIN" ]; then
  echo "❌ Error: ENV_NGROK_DOMAIN is not set." >&2
  echo "Please set it in your command: export ENV_NGROK_DOMAIN='https://your-domain...'" >&2
  exit 1
fi

# Read the token from an environment variable passed at runtime
NGROK_AUTHTOKEN_DEFAULT="${ENV_NGROK_TOKEN}"

# Check if the variable is empty. If so, fail.
if [ -z "$NGROK_AUTHTOKEN_DEFAULT" ]; then
  echo "❌ Error: ENV_NGROK_TOKEN is not set." >&2
  echo "Please set it in your command: export ENV_NGROK_TOKEN='your_token'" >&2
  exit 1
fi

# Persistent Data Path
N8N_DATA_HOST_PATH_DEFAULT="./n8n-data"

# Configuration for GDrive Download (Script 1 integration)
GDRIVE_URL_FILE="gdrive-cmds" # File to read URL from in 'auto' mode
FILE_ID="" # Will be set dynamically by get_gdrive_info()
FILENAME="n8n-data.zip"
VENV_NAME="gdrive_env" # Virtual environment for gdown

# --- 2. FUNCTION DEFINITIONS ---

# Function to display usage information
usage() {
    echo "Usage: $0 {start|stop|logs|setup}"
    echo "  start - Installs dependencies, downloads data, sets up files, and starts N8N/Ngrok."
    echo "  stop  - Stops and removes the N8N container and the background Ngrok process."
    echo "  logs  - Displays N8N logs (Press Ctrl+C to exit)."
    echo "  setup - Forces recreation of .env and docker-compose.yml files."
    exit 1
}

# --- GET GOOGLE DRIVE URL AND EXTRACT FILE ID ---
get_gdrive_info() {
    echo ""
    echo "--- 🔑 Google Drive Data URL Input ---"
    
    # Only prompt if FILE_ID is not already set
    if [ -z "$FILE_ID" ]; then
        local GDRIVE_URL=""
        local INPUT_MODE=""

        # Ask user for input mode
        read -p "Get GDrive URL automatically from '$GDRIVE_URL_FILE' file? (auto/manual) [auto]: " INPUT_MODE
        
        # Default to 'auto' if user just hits Enter
        if [ -z "$INPUT_MODE" ]; then
            INPUT_MODE="auto"
        fi

        if [[ "$INPUT_MODE" == "auto" ]]; then
            echo "--- Using 'auto' mode ---"
            if [ -f "$GDRIVE_URL_FILE" ]; then
                # Read the first line of the file
                GDRIVE_URL=$(head -n 1 "$GDRIVE_URL_FILE")
                if [ -z "$GDRIVE_URL" ]; then
                    echo "❌ Error: '$GDRIVE_URL_FILE' is empty. Falling back to manual input."
                    INPUT_MODE="manual" # Force manual input
                else
                    echo "✅ Found URL in $GDRIVE_URL_FILE."
                fi
            else
                echo "❌ Error: File '$GDRIVE_URL_FILE' not found. Falling back to manual input."
                INPUT_MODE="manual" # Force manual input
            fi
        fi

        if [[ "$INPUT_MODE" == "manual" ]]; then
            echo "--- Using 'manual' mode ---"
            read -p "Please paste the Google Drive URL for the n8n data zip: " GDRIVE_URL
        fi
        
        if [ -z "$GDRIVE_URL" ]; then
            echo "❌ Error: Google Drive URL cannot be empty. Exiting deployment."
            exit 1
        fi
        
        # Robust extraction logic for common Google Drive URL formats:
        EXTRACTED_ID=$(echo "$GDRIVE_URL" | awk -F'[/=]' '{
            for (i=1; i<=NF; i++) {
                if ($i == "d" && $(i+1) != "") { print $(i+1); exit }
                if ($i == "id") { print $(i+1); exit }
            }
        }')

        if [ -z "$EXTRACTED_ID" ]; then
            echo "❌ Error: Could not reliably extract File ID from the provided URL."
            echo "Please ensure the URL is valid. URL was: '$GDRIVE_URL'"
            exit 1
        fi
        
        # Set the global variable
        FILE_ID="$EXTRACTED_ID"
        
        echo "✅ Extracted File ID: $FILE_ID"
    fi
}


# --- SETUP ENVIRONMENT FILE (.env) ---
setup_env() {
    # We always regenerate the environment file to ensure the static domain is set
    echo "--- Initial Setup: Creating $ENV_FILE ---"

    cat <<EOF > "$ENV_FILE"
# ----------------------------------------------------------------------
# N8N CONFIGURATION (Using static Ngrok domain)
# ----------------------------------------------------------------------
N8N_DATA_HOST_PATH=${N8N_DATA_HOST_PATH_DEFAULT}
N8N_PUBLIC_URL=${STATIC_NGROK_DOMAIN}

# N8n environment variables using the static public URL
EDITOR_BASE_URL=${STATIC_NGROK_DOMAIN}/
WEBHOOK_URL=${STATIC_NGROK_DOMAIN}/
N8N_DEFAULT_BINARY_DATA_MODE=filesystem
N8N_COMMUNITY_PACKAGES_ALLOW_TOOL_USAGE=true
N8N_RUNNERS_ENABLED=true

# ----------------------------------------------------------------------
# NGROK CONFIGURATION (Host install)
# ----------------------------------------------------------------------
NGROK_AUTHTOKEN=${NGROK_AUTHTOKEN_DEFAULT}
EOF

    echo "✅ $ENV_FILE created successfully."
    echo "⚠️ NOTE: N8N is configured for the static domain: ${STATIC_NGROK_DOMAIN}"
}

# --- CREATE DOCKER COMPOSE FILE ---
create_docker_compose() {
    echo "--- Creating $COMPOSE_FILE ---"
    cat <<EOF > "$COMPOSE_FILE"
version: '3.7'

services:
  # N8N APPLICATION SERVICE
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: always
    # --- FIX for Exit Code 137 (Out of Memory) ---
    # Reserve 1GB and limit to 2GB to stabilize Node.js process during migrations
    mem_limit: 2048m  # Hard limit of 2GB
    mem_reservation: 1024m # Reserve 1GB
    environment:
      # Increase Node.js heap size to avoid memory issues during migrations/heavy load
      - NODE_OPTIONS=--max_old_space_size=1500
      # --- END FIX ---
      
      # Load all N8N_* variables from the .env file
      - EDITOR_BASE_URL=\${EDITOR_BASE_URL}
      - WEBHOOK_URL=\${WEBHOOK_URL}
      - N8N_DEFAULT_BINARY_DATA_MODE=\${N8N_DEFAULT_BINARY_DATA_MODE}
      - N8N_COMMUNITY_PACKAGES_ALLOW_TOOL_USAGE=\${N8N_COMMUNITY_PACKAGES_ALLOW_TOOL_USAGE}
      - N8N_RUNNERS_ENABLED=\${N8N_RUNNERS_ENABLED}
    volumes:
      # Persistent storage mapping to your host server's local data path
      - \${N8N_DATA_HOST_PATH}:/home/node/.n8n
    ports:
      # Expose N8N to the host machine for the host-installed ngrok client to access.
      - "${N8N_INTERNAL_PORT}:${N8N_INTERNAL_PORT}"
    networks:
      - default

networks:
  default:
    driver: bridge
EOF

    echo "✅ $COMPOSE_FILE created successfully (with memory limits added)."
}

# --- INSTALL DOCKER, NGROK, AND PYTHON BASE DEPENDENCIES ---
install_dependencies() {
    echo ""
    echo "--- Installing System Dependencies (Docker, Ngrok, Python/Venv, Unzip, Git) ---"
    echo "⚠️ WARNING: This requires 'sudo' privileges to modify the system."

    # 1. Update package lists
    sudo apt update > /dev/null 2>&1
    echo "✅ System packages updated."

    # 2. Install necessary packages
    echo "Installing essential packages..."
    # *** ADDED git TO THIS LIST ***
    sudo apt install -y ca-certificates curl gnupg lsb-release python3-pip python3-full python3-venv unzip git

    # 3. Install Docker
    if ! command -v docker &> /dev/null; then
        echo "Installing Docker..."
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
          $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

        sudo apt update > /dev/null 2>&1
        sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

        # Add user to docker group
        if ! getent group docker > /dev/null; then sudo groupadd docker; fi
        sudo usermod -aG docker "$USER"
        echo "✅ Docker installed."
    else
        echo "✅ Docker found. Skipping installation."
    fi

    # 4. Install Ngrok
    if ! command -v ngrok &> /dev/null; then
        echo "Installing Ngrok..."
        curl -sSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc \
          | sudo tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null \
          && echo "deb https://ngrok-agent.s3.amazonaws.com bookworm main" \
          | sudo tee /etc/apt/sources.list.d/ngrok.list \
          && sudo apt update > /dev/null 2>&1 \
          && sudo apt install -y ngrok
        echo "✅ Ngrok installed."
    else
        echo "✅ Ngrok found. Skipping installation."
    fi

    # 5. Configure Ngrok Authtoken on Host
    echo "--- Configuring Ngrok Authtoken ---"
    # This now uses the secure variable passed in from the environment
    sudo ngrok config add-authtoken "${NGROK_AUTHTOKEN_DEFAULT}"
    echo "✅ Ngrok authtoken configured on host."
}

# --- DOWNLOAD AND PREPARE N8N DATA (Script 1 Logic) ---
download_n8n_data() {
    echo ""
    echo "--- 🔄 Starting N8N Persistent Data Preparation ---"

    if [ -z "$FILE_ID" ]; then
        echo "❌ Error: Google Drive File ID is not set. Cannot download data. Exiting deployment."
        exit 1
    fi

    # 1. Create and activate virtual environment for gdown
    if [ ! -d "$VENV_NAME" ]; then
        echo "Creating virtual environment: $VENV_NAME"
        python3 -m venv "$VENV_NAME"
    fi

    # 2. Install gdown inside the virtual environment
    echo "Installing gdown into $VENV_NAME..."
    source "$VENV_NAME/bin/activate" && pip install gdown > /dev/null 2>&1
    
    if [ ! -f "$VENV_NAME/bin/gdown" ]; then
        echo "❌ gdown installation failed. Cannot proceed with download. Exiting deployment."
        exit 1
    fi
    echo "✅ gdown is installed and ready."

    # 3. Create host data directory if it doesn't exist
    if [ ! -d "$N8N_DATA_HOST_PATH_DEFAULT" ]; then
        mkdir -p "$N8N_DATA_HOST_PATH_DEFAULT"
        echo "✅ Created persistent data directory: $N8N_DATA_HOST_PATH_DEFAULT"
    fi

    # 4. Execute gdown command
    echo "--- 📥 Downloading Google Drive File (ID: ${FILE_ID}) using gdown ---"
    gdown --id "${FILE_ID}" --output "${FILENAME}" --no-cookies --fuzzy

    DOWNLOAD_STATUS=$?
    deactivate # Deactivate environment immediately after use

    if [ $DOWNLOAD_STATUS -ne 0 ] || [ ! -s "${FILENAME}" ]; then
        echo "❌ Download failed or file is empty. Exiting deployment."
        exit 1
    fi

    echo "✅ Download complete (File size: $(du -h "${FILENAME}" | awk '{print $1}'))."
    echo ""

    # 5. Unzip the file into the host data path
    echo "--- 📂 Unzipping ${FILENAME} to ${N8N_DATA_HOST_PATH_DEFAULT} ---"
    # Use -o (overwrite) and extract directly into the target directory
    unzip -o "${FILENAME}" -d "$N8N_DATA_HOST_PATH_DEFAULT"

    if [ $? -ne 0 ]; then
        echo "❌ WARNING: Unzip failed. The downloaded file might be corrupted. Continuing cleanup."
    else
        echo "✅ File extraction attempted."

        # --- FIX: Check for and fix common nested directory issue (e.g., ./n8n-data/n8n-data) ---
        NESTED_PATH="${N8N_DATA_HOST_PATH_DEFAULT}/$(basename "$N8N_DATA_HOST_PATH_DEFAULT")"
        if [ -d "$NESTED_PATH" ] && [ -n "$(ls -A "$NESTED_PATH")" ]; then
            echo "--- ⚠️ Nested directory detected! Fixing data path... ---"
            # Move all contents from the nested folder up one level, handling hidden files
            find "$NESTED_PATH" -mindepth 1 -maxdepth 1 -exec mv -t "$N8N_DATA_HOST_PATH_DEFAULT" {} +
            # Remove the now-empty nested directory
            rmdir "$NESTED_PATH"
            echo "✅ Data moved to the correct root path: ${N8N_DATA_HOST_PATH_DEFAULT}"
        fi
        # --- End Nesting Fix ---
    fi

    # 6. Cleanup
    echo "--- 🧹 Cleaning up zip archive ---"
    rm -f "${FILENAME}"
    # Leaving the venv for future use
    echo "✅ Removed ${FILENAME}. Environment '$VENV_NAME' remains for future use."
    echo ""
}

# --- DEPLOYMENT AND MANAGEMENT FUNCTIONS ---

deploy() {
    # 1. Prompt user for Google Drive URL and extract the File ID
    # This function now handles auto/manual logic
    get_gdrive_info
    
    # 2. Install Dependencies (Docker, Ngrok, Python, Unzip, Git)
    install_dependencies

    # 3. Setup config files (.env and docker-compose.yml)
    setup_env
    create_docker_compose

    # 4. Download and populate N8N data directory
    download_n8n_data

    # 5. Ensure correct ownership for the n8n container user (UID 1000)
    echo "--- Setting Permissions on Data Directory ---"
    if sudo chown -R 1000:1000 "$N8N_DATA_HOST_PATH_DEFAULT"; then
        echo "✅ Set correct ownership (1000:1000) for n8n persistence."
    else
        echo "❌ WARNING: Failed to set ownership (chown) on $N8N_DATA_HOST_PATH_DEFAULT. Check file system status."
    fi

    echo "--- Starting N8N Deployment ---"
    # Clean up previous runs
    docker compose -f "$COMPOSE_FILE" down --remove-orphans > /dev/null 2>&1
    docker compose -f "$COMPOSE_FILE" pull # Ensure latest images
    docker compose -f "$COMPOSE_FILE" up -d --build

    if [ $? -eq 0 ]; then
        echo ""
        echo "=========================================================="
        echo "🚀 STEP 1/2: N8N DOCKER DEPLOYMENT COMPLETED!"
        echo "N8N is running on your server's host port 5678."
        
        # --- Start Ngrok Tunnel Automatically (Detached Mode) ---
        echo ""
        echo "--- Starting Ngrok Tunnel Automatically (Detached) ---"
        
        # 1. Kill previous ngrok process if running (to avoid binding errors)
        echo "Attempting to terminate any existing ngrok process..."
        sudo pkill ngrok || true
        sleep 1 # Give time for process to terminate

        # 2. Execute the ngrok command in the background
        NGROK_HOSTNAME="${STATIC_NGROK_DOMAIN#https://}"
        NGROK_CMD="sudo ngrok http --domain=${NGROK_HOSTNAME} ${N8N_INTERNAL_PORT}"
        echo "Executing: $NGROK_CMD &"
        # The '&' runs the command in the background (detached mode)
        $NGROK_CMD &
        
        echo "✅ Ngrok tunnel started in the background."
        
        echo ""
        echo "=========================================================="
        echo "🚀 STEP 2/2: NGROK TUNNEL STARTED!"
        echo "Access your N8N instance at:"
        echo "----------------------------------------------------------"
        echo "${STATIC_NGROK_DOMAIN}"
        echo "----------------------------------------------------------"
        echo "=========================================================="
    else
        echo "Deployment failed. Check Docker status."
    fi
}

stop_deployment() {
    echo "--- Stopping Deployment ---"
    # Kill the background ngrok process first
    echo "Stopping background ngrok process..."
    sudo pkill ngrok || true
    
    # Stop and remove the Docker container
    if [ -f "$COMPOSE_FILE" ]; then
        docker compose -f "$COMPOSE_FILE" down --remove-orphans
        echo "N8N container stopped and removed."
    else
        echo "No docker-compose.yml file found. Skipping Docker stop."
    fi
}

show_logs() {
    echo "--- Showing N8N Container Logs (Press Ctrl+C to exit) ---"
    if [ -f "$COMPOSE_FILE" ]; then
        docker compose -f "$COMPOSET_FILE" logs -f n8n
    else
        echo "Error: docker-compose.yml not found. Run 'start' first."
    fi
}

# --- 3. MAIN EXECUTION ---
case "$1" in
    start)
        deploy
        ;;

    stop)
        stop_deployment
        ;;

    logs)
        show_logs
        ;;

    setup)
        # Force recreation of files
        rm -f "$ENV_FILE" "$COMPOSE_FILE"
        setup_env
        create_docker_compose
        ;;

    *)
        usage
        ;;
esac

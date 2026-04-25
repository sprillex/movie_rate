#!/bin/bash

# ==============================================================================
# SCRIPT: Generic Python Service Manager
# VERSION: 7.0
# AUTHOR: User / Gemini
# TARGET OS: Linux (Debian/Ubuntu/Mint derivatives)
#
# DESCRIPTION:
#   A comprehensive lifecycle manager for Python systemd services.
#   Handles installation, testing, upgrading (with git), and uninstallation.
#   Designed to be read by Humans and AI agents for automated deployment.
#
# AI / LLM CONTEXT:
#   - Language: Bash
#   - Root Required: Yes (for systemd/install operations)
#   - Dependencies: python3, python3-venv, git, systemd
#   - Config File: service_config.env (Created interactively)
#   - Secrets: secrets.env (Managed locally, never committed)
#   - Template: example.env (Used for auto-discovery of secrets)
#
# USAGE:
#   ./update.sh [OPTION]
#
# OPTIONS:
#   (No args)       : Launches Interactive Menu (Recommended)
#   -u, --update    : Pulls git changes, updates venv, and restarts service (Alias for --upgrade)
#   -m, --main      : Forces update using the 'main' git branch
#   -n, --newest    : Forces update using the most recently updated local git branch
#   -c, --settings  : Opens the configuration manager
#   -s, --status    : Checks the status of the service
#   -l, --logs      : Views the last 50 lines of logs
#   -r, --restart   : Restarts the systemd service
#   -h, --help      : Displays this help message
#   --test          : Runs script locally in a temp venv (Testing Phase)
#   --cleanup-test  : Removes temp venv and kills stray processes
#   --install       : Deploys application to /opt and registers systemd service
#   --uninstall     : Stops service, removes systemd unit, and deletes files
#
# KEY VARIABLES (Saved to service_config.env):
#   SERVICE_NAME    : systemd unit name (e.g., weather_bot)
#   SERVICE_DESC    : Description for systemctl status
#   MAIN_SCRIPT     : Python entry point (e.g., main.py)
#   INSTALL_DIR     : Deployment path (Default: /opt/SERVICE_NAME)
#   SERVICE_USER    : Non-root user to run the specific service
#
# SECRET MANAGEMENT:
#   - Looks for 'example.env' to prompt user for specific keys.
#   - Saves keys to 'secrets.env' (chmod 600).
#   - Installs secrets to /opt/... and uses 'EnvironmentFile' in systemd.
#
# SELF-UPDATE MECHANISM:
#   The script calculates its own SHA256 checksum before and after a git pull.
#   If the checksum differs, it re-executes itself to apply logic updates.
# ==============================================================================

CONFIG_FILE="service_config.env"
SECRETS_FILE="secrets.env"
TEMPLATE_FILE="example.env"
COMMON_PORTS_FILE="common_ports_do_not_use.csv"

# ANSI Colors
COLORS_RED='\033[0;31m'
COLORS_GREEN='\033[0;32m'
COLORS_YELLOW='\033[1;33m'
COLORS_BLUE='\033[0;34m'
COLORS_NC='\033[0m' # No Color

# --- Helper Functions ---

log_info() { echo -e "${COLORS_GREEN}[INFO]${COLORS_NC} $1"; }
log_warn() { echo -e "${COLORS_YELLOW}[WARN]${COLORS_NC} $1"; }
log_error() { echo -e "${COLORS_RED}[ERROR]${COLORS_NC} $1"; }
log_header() { echo -e "${COLORS_BLUE}$1${COLORS_NC}"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This operation requires root privileges. Please run with sudo."
        exit 1
    fi
}

check_dependencies() {
    local missing=0
    for cmd in python3 git curl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Missing required command: $cmd"
            missing=1
        fi
    done

    # Check for venv module explicitly
    if command -v python3 >/dev/null 2>&1; then
        if ! python3 -m venv --help >/dev/null 2>&1; then
            log_error "Missing python3-venv module. Please install it (e.g., sudo apt install python3-venv)."
            missing=1
        fi
    fi

    # Check for systemctl if we are on a system that should use it
    if [ -d "/run/systemd/system" ] || [ -n "$SYSTEMD_PID" ]; then
        if ! command -v systemctl >/dev/null 2>&1; then
            log_error "Missing systemctl command."
            missing=1
        fi
    fi

    if [ "$missing" -eq 1 ]; then
        exit 1
    fi
}

wait_for_healthcheck() {
    local url="$1"
    local max_retries=30 # 30 seconds
    local count=0

    if [ -z "$url" ]; then return 0; fi

    log_info "Waiting for service to initialize (up to ${max_retries}s)..."

    while [ "$count" -lt "$max_retries" ]; do
        if curl -f -s -o /dev/null "$url"; then
            echo "" # Newline
            log_info "SUCCESS: Service is responding at $url"
            return 0
        fi
        sleep 1
        count=$((count + 1))
        echo -ne "."
    done
    echo "" # Newline

    log_warn "WARNING: Service failed to respond at $url after ${max_retries} seconds"
    log_warn "Check logs with: journalctl -u $SERVICE_NAME"
    return 1
}

# --- Input Handling & Validation ---

# Function to check if a port is in use
is_port_in_use() {
    local port=$1
    if command -v lsof >/dev/null 2>&1; then
        lsof -i ":$port" >/dev/null 2>&1
        return $?
    elif command -v ss >/dev/null 2>&1; then
        ss -tuln | grep -q ":$port "
        return $?
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tuln | grep -q ":$port "
        return $?
    else
        log_warn "Could not check if port $port is in use (missing lsof/ss/netstat)."
        return 1 # Assume free if we can't check
    fi
}

# Function to check if a port is in the forbidden list
is_port_forbidden() {
    local port=$1
    if [ -f "$COMMON_PORTS_FILE" ]; then
        if grep -q "^$port," "$COMMON_PORTS_FILE"; then
            return 0 # True, it is forbidden
        fi
    fi
    return 1 # False
}

select_port() {
    local var_name="$1"
    local default_port="$2"
    local selected_port=""

    # Stop service if running to free up the port for checking
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_info "Stopping service momentarily to check port availability..."
        systemctl stop "$SERVICE_NAME"
    fi

    while true; do
        get_input "Enter Service Port (1024-65535)" "$var_name" "$default_port"
        selected_port="${!var_name}"

        # 1. Numeric check
        if [[ ! "$selected_port" =~ ^[0-9]+$ ]]; then
            log_error "Port must be a number."
            continue
        fi

        # 2. Privileged check
        if [ "$selected_port" -lt 1024 ]; then
            log_error "Port $selected_port is a privileged port (<1024). Please choose a higher port."
            continue
        fi

        # 3. Forbidden list check
        if is_port_forbidden "$selected_port"; then
            local reason=$(grep "^$selected_port," "$COMMON_PORTS_FILE" | cut -d',' -f2)
            log_error "Port $selected_port is reserved/common ($reason). Please choose another."
            continue
        fi

        # 4. Usage check
        if is_port_in_use "$selected_port"; then
             log_error "Port $selected_port is currently in use by another process."
             continue
        fi

        log_info "Port $selected_port is available."
        break
    done
}


get_input() {
    local prompt_text="$1"
    local var_name="$2"
    local default_val="$3"
    local input_val=""

    while true; do
        if [ -n "$default_val" ]; then
            echo -ne "${prompt_text} [${COLORS_YELLOW}${default_val}${COLORS_NC}]: "
        else
            echo -ne "${prompt_text}: "
        fi

        read input_val
        input_val=$(echo "$input_val" | xargs) # Trim whitespace

        # Global Exit
        if [[ "${input_val,,}" == "exit" ]] || [[ "$input_val" == "9" ]]; then
            log_warn "Exit requested by user."
            exit 0
        fi

        # Empty Check
        if [ -z "$input_val" ]; then
            if [ -n "$default_val" ]; then
                input_val="$default_val"
            else
                log_error "This value cannot be empty. Please try again (or type 'exit')."
                continue
            fi
        fi

        # Validation per variable type
        case "$var_name" in
            SERVICE_USER)
                if ! id "$input_val" &>/dev/null; then
                    log_error "User '$input_val' does not exist on this system."
                    continue
                fi
                ;;
            SERVICE_NAME)
                if [[ ! "$input_val" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                    log_error "Service name contains invalid characters. Use (a-z, 0-9, _, -)."
                    continue
                fi
                ;;
        esac

        break
    done
    eval "$var_name=\"$input_val\""
}

# --- Git Branch Logic (Not Saved) ---

select_git_branch() {
    # If the branch was already set via flags (--main or --newest), skip prompt.
    if [ -n "$CURRENT_GIT_BRANCH" ]; then
        log_info "Using overridden git branch: $CURRENT_GIT_BRANCH"
        return
    fi

    echo "----------------------------------------"
    echo "Git Branch Selection:"
    echo "1. Main (Use 'main' branch)"
    echo "2. Newest (Auto-detect most recently updated local branch)"
    echo "3. Choose Later (Fetch and list all remote branches)"
    echo "----------------------------------------"

    get_input "Select branch option" "BRANCH_OPT" "1"

    case "$BRANCH_OPT" in
        1) CURRENT_GIT_BRANCH="main" ;;
        2)
            if [ -d ".git" ]; then
                NEWEST=$(git for-each-ref --sort=-committerdate refs/heads/ --format='%(refname:short)' | head -n 1)
                CURRENT_GIT_BRANCH="${NEWEST:-main}"
                log_info "Detected newest branch: $CURRENT_GIT_BRANCH"
            else
                log_warn "Not a git repo. Defaulting to main."
                CURRENT_GIT_BRANCH="main"
            fi
            ;;
        3)
            if [ -d ".git" ]; then
                log_info "Fetching remote branches..."
                git fetch --all --quiet
                echo "Available Remote Branches:"
                git branch -r | grep -v "HEAD" | sed 's/origin\///' | sed 's/^/  - /'
                echo "----------------------------------------"
                get_input "Type the exact branch name to use" "CURRENT_GIT_BRANCH" "main"
            else
                 log_warn "Not a git repo. Defaulting to main."
                 CURRENT_GIT_BRANCH="main"
            fi
            ;;
        *) CURRENT_GIT_BRANCH="main" ;;
    esac
}

# --- Secrets Management ---

save_secret() {
    local key="$1"
    local val="$2"
    # Remove existing key if present
    if [ -f "$SECRETS_FILE" ]; then
        sed -i "/^$key=/d" "$SECRETS_FILE"
    fi
    echo "$key=$val" >> "$SECRETS_FILE"
    log_info "Saved $key"
}

manage_secrets() {
    echo "========================================"
    log_header "API KEYS & SECRETS"
    echo "========================================"

    # --- Port Selection (Dynamic) ---
    local current_port="5000"
    if [ -f "$SECRETS_FILE" ]; then
        local saved_port=$(grep "^PORT=" "$SECRETS_FILE" | cut -d'=' -f2-)
        if [ -n "$saved_port" ]; then current_port="$saved_port"; fi
    fi

    select_port "SERVICE_PORT" "$current_port"
    save_secret "PORT" "$SERVICE_PORT"

    # --- Other Secrets ---

    if [ -f "$SECRETS_FILE" ]; then
        log_info "Found existing secrets file: $SECRETS_FILE"
        get_input "Do you want to review/edit other secrets? (y/n)" "EDIT_SECRETS" "n"
    else
        get_input "Do you need to configure other API keys? (y/n)" "EDIT_SECRETS" "n"
    fi

    if [[ "${EDIT_SECRETS,,}" != "y" ]]; then
        return 0
    fi

    # MODE 1: Auto-Discovery via example.env
    if [ -f "$TEMPLATE_FILE" ]; then
        log_info "Found template '$TEMPLATE_FILE'. Detecting required keys..."

        while IFS='=' read -r key value || [ -n "$key" ]; do
            # Skip comments (#) and empty lines
            [[ "$key" =~ ^#.*$ ]] && continue
            [[ -z "$key" ]] && continue

            key=$(echo "$key" | xargs)

            # Skip PORT as we already handled it
            if [[ "$key" == "PORT" ]]; then continue; fi

            current_val=""
            if [ -f "$SECRETS_FILE" ]; then
                current_val=$(grep "^$key=" "$SECRETS_FILE" | cut -d'=' -f2-)
            fi

            echo -ne "Enter value for ${COLORS_BLUE}$key${COLORS_NC} "
            if [ -n "$current_val" ]; then
                echo -ne "[${COLORS_YELLOW}*******${COLORS_NC}]: "
            else
                echo -ne "[${COLORS_YELLOW}None${COLORS_NC}]: "
            fi

            read input_val

            if [ -n "$input_val" ]; then
                save_secret "$key" "$input_val"
            elif [ -z "$current_val" ]; then
                 log_warn "Skipping $key (No value provided)"
            else
                 log_info "Keeping existing value for $key"
            fi

        done < "$TEMPLATE_FILE"

    else
        # MODE 2: Manual Entry (Fallback)
        log_warn "No '$TEMPLATE_FILE' found. Manual entry mode."
        log_info "Type 'DONE' as the Key Name to finish."

        while true; do
            read -p "Enter Key Name (e.g. OPENAI_KEY) [or DONE]: " KEY_NAME
            if [[ "${KEY_NAME,,}" == "done" ]] || [[ -z "$KEY_NAME" ]]; then
                break
            fi
            read -p "Enter Value for $KEY_NAME: " KEY_VALUE
            if [ -n "$KEY_VALUE" ]; then
                save_secret "$KEY_NAME" "$KEY_VALUE"
            fi
        done
    fi

    if [ -f "$SECRETS_FILE" ]; then
        chmod 600 "$SECRETS_FILE"
    fi
}

# --- Configuration Management ---

save_config() {
    cat > "$CONFIG_FILE" <<EOF
SERVICE_NAME="$SERVICE_NAME"
SERVICE_DESC="$SERVICE_DESC"
MAIN_SCRIPT="$MAIN_SCRIPT"
INSTALL_DIR="$INSTALL_DIR"
SERVICE_USER="$SERVICE_USER"
BACKUP_FILES="$BACKUP_FILES"
GIT_FORCE_RESET="$GIT_FORCE_RESET"
HEALTHCHECK_URL="$HEALTHCHECK_URL"
EOF
    log_info "Configuration saved to $CONFIG_FILE"
}

manage_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"

        echo "========================================"
        log_header "CURRENT CONFIGURATION"
        echo "========================================"
        echo "1. Service Name : $SERVICE_NAME"
        echo "2. Description  : $SERVICE_DESC"
        echo "3. Main Script  : $MAIN_SCRIPT"
        echo "4. Install Dir  : $INSTALL_DIR"
        echo "5. Service User : $SERVICE_USER"
        echo "6. Backup Files : ${BACKUP_FILES:-None}"
        echo "7. Force Reset  : ${GIT_FORCE_RESET:-false}"
        echo "8. Health Check : ${HEALTHCHECK_URL:-None}"
        echo "----------------------------------------"

        get_input "Do you want to edit this configuration? (y/n)" "EDIT_CHOICE" "n"

        if [[ "${EDIT_CHOICE,,}" != "y" ]]; then
            if [[ -z "$SERVICE_NAME" || -z "$SERVICE_USER" || -z "$MAIN_SCRIPT" ]]; then
                log_warn "Missing required values. Forcing edit mode."
            else
                return 0
            fi
        fi
    else
        log_info "No configuration found. Starting setup."
    fi

    echo "========================================"
    log_header "CONFIGURATION SETUP"
    echo "Type 'exit' or '9' to quit at any time."
    echo "========================================"

    get_input "Enter Service Name (systemd name)" "SERVICE_NAME" "$SERVICE_NAME"
    get_input "Enter Service Description" "SERVICE_DESC" "$SERVICE_DESC"
    get_input "Enter Python Main Script Filename" "MAIN_SCRIPT" "$MAIN_SCRIPT"

    DEFAULT_DIR="/opt/$SERVICE_NAME"
    get_input "Enter Install Directory" "INSTALL_DIR" "${INSTALL_DIR:-$DEFAULT_DIR}"

    SUGGESTED_USER="${SUDO_USER:-root}"
    get_input "Enter Service User" "SERVICE_USER" "${SERVICE_USER:-$SUGGESTED_USER}"

    echo "----------------------------------------"
    echo "ADVANCED OPTIONS"
    get_input "Enter filenames to backup on upgrade (space separated, or leave empty)" "BACKUP_FILES" "${BACKUP_FILES}"

    echo "FORCE GIT RESET: If 'true', local changes will be discarded on upgrade."
    echo "Use this for 'appliance' style deployments."
    get_input "Enable Force Git Reset? (true/false)" "GIT_FORCE_RESET" "${GIT_FORCE_RESET:-false}"

    echo "HEALTH CHECK URL: Optional URL to curl after start to verify connectivity."
    echo "Example: http://127.0.0.1:5000/health (Leave empty to skip)"
    get_input "Enter Health Check URL" "HEALTHCHECK_URL" "${HEALTHCHECK_URL}"

    save_config
}

# --- Phase: Testing ---

do_test() {
    log_header "PHASE: TESTING"
    manage_config
    manage_secrets

    if [ ! -d "venv" ]; then
        log_info "Creating temporary local virtual environment..."
        python3 -m venv venv
    fi

    source venv/bin/activate

    if [ -f "requirements.txt" ]; then
        pip install -r requirements.txt
    fi

    if [ -f "$SECRETS_FILE" ]; then
        log_info "Loading API keys from $SECRETS_FILE..."
        set -a
        source "$SECRETS_FILE"
        set +a
    fi

    log_info "Running $MAIN_SCRIPT in test mode..."
    log_info "Press Ctrl+C to stop."

    # Run in background and capture PID
    python3 "$MAIN_SCRIPT" &
    TEST_PID=$!
    echo "$TEST_PID" > .test_pid

    # Trap Ctrl+C to clean up properly
    trap 'kill $TEST_PID 2>/dev/null; rm -f .test_pid; echo ""; log_info "Test process stopped."' INT

    # Wait for the process
    wait $TEST_PID

    # Restore default Ctrl+C behavior
    trap - INT

    rm -f .test_pid
    deactivate
}

do_test_cleanup() {
    log_header "PHASE: TESTING DONE (CLEANUP)"
    manage_config

    if [ -f ".test_pid" ]; then
        TEST_PID=$(cat .test_pid)
        if kill -0 "$TEST_PID" 2>/dev/null; then
            log_warn "Stopping running test instance (PID: $TEST_PID)..."
            kill "$TEST_PID"
        fi
        rm -f .test_pid
    else
        log_info "No saved test PID found."
    fi

    if [ -d "venv" ]; then
        log_info "Removing local 'venv' directory..."
        rm -rf "venv"
    fi

    if [ -f "$SECRETS_FILE" ]; then
        log_info "Removing local secrets file..."
        rm -f "$SECRETS_FILE"
    fi

    find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null
    log_info "Cleanup complete."
}

# --- Phase: Install ---

do_install() {
    log_header "PHASE: INSTALL SERVICE"
    check_root
    check_dependencies
    manage_config
    select_git_branch
    manage_secrets

    SERVICE_GROUP=$(id -gn "$SERVICE_USER")

    log_info "Installing $SERVICE_NAME (Branch: $CURRENT_GIT_BRANCH)..."

    if [ -d ".git" ]; then
         log_info "Checking for updates from GitHub (Branch: $CURRENT_GIT_BRANCH)..."
         CHECKSUM_BEFORE=$(sha256sum "$0" | awk '{print $1}')

         git checkout "$CURRENT_GIT_BRANCH"
         git pull origin "$CURRENT_GIT_BRANCH"

         CHECKSUM_AFTER=$(sha256sum "$0" | awk '{print $1}')

         if [ "$CHECKSUM_BEFORE" != "$CHECKSUM_AFTER" ]; then
             log_warn "INSTALLER SCRIPT UPDATED - RESTARTING..."
             exec "$0" --install --branch "$CURRENT_GIT_BRANCH"
         fi
    fi

    if [ ! -d "$INSTALL_DIR" ]; then mkdir -p "$INSTALL_DIR"; fi

    cp "$MAIN_SCRIPT" "$INSTALL_DIR/"
    if [ -f "requirements.txt" ]; then cp "requirements.txt" "$INSTALL_DIR/"; fi

    if [ -f "$SECRETS_FILE" ]; then
        log_info "Installing secrets file..."
        cp "$SECRETS_FILE" "$INSTALL_DIR/$SECRETS_FILE"
        chmod 600 "$INSTALL_DIR/$SECRETS_FILE"
        chown "$SERVICE_USER":"$SERVICE_GROUP" "$INSTALL_DIR/$SECRETS_FILE"
    fi

    chown -R "$SERVICE_USER":"$SERVICE_GROUP" "$INSTALL_DIR"
    log_info "Setting up Production Virtual Environment..."
    if ! su - "$SERVICE_USER" -c "python3 -m venv $INSTALL_DIR/venv"; then
        log_error "Failed to create venv."
        exit 1
    fi

    if [ -f "$INSTALL_DIR/requirements.txt" ]; then
        su - "$SERVICE_USER" -c "$INSTALL_DIR/venv/bin/pip install -r $INSTALL_DIR/requirements.txt"
    fi

    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=$SERVICE_DESC
After=network.target

[Service]
User=$SERVICE_USER
Group=$SERVICE_GROUP
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/$MAIN_SCRIPT
Restart=always
RestartSec=10
EOF

    if [ -f "$SECRETS_FILE" ]; then
        echo "EnvironmentFile=$INSTALL_DIR/$SECRETS_FILE" >> "$SERVICE_FILE"
    fi

    cat >> "$SERVICE_FILE" <<EOF

[Install]
WantedBy=multi-user.target
EOF

    chown -R "$SERVICE_USER":"$SERVICE_GROUP" "$INSTALL_DIR"
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"
    log_info "Service Started."

    if [ -n "$HEALTHCHECK_URL" ]; then
        wait_for_healthcheck "$HEALTHCHECK_URL"
    fi

    log_info "Installation Complete!"
}

# --- Phase: Upgrade ---

do_upgrade() {
    log_header "PHASE: UPGRADE SERVICE"
    check_root
    check_dependencies
    manage_config
    select_git_branch

    SERVICE_GROUP=$(id -gn "$SERVICE_USER")

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_warn "Stopping service $SERVICE_NAME..."
        systemctl stop "$SERVICE_NAME"
    fi

    # --- Backup Phase ---
    if [ -n "$BACKUP_FILES" ]; then
        log_info "Backing up specified files..."
        TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        for file in $BACKUP_FILES; do
            if [ -f "$INSTALL_DIR/$file" ]; then
                log_info "Backing up $file to $file.bak_$TIMESTAMP"
                cp "$INSTALL_DIR/$file" "$INSTALL_DIR/$file.bak_$TIMESTAMP"
                chown "$SERVICE_USER":"$SERVICE_GROUP" "$INSTALL_DIR/$file.bak_$TIMESTAMP"
            else
                log_warn "Backup file $file not found in $INSTALL_DIR"
            fi
        done
    fi

    # --- Git Update Phase ---
    if [ -d ".git" ]; then
        log_info "Checking for updates from GitHub (Branch: $CURRENT_GIT_BRANCH)..."
        CHECKSUM_BEFORE=$(sha256sum "$0" | awk '{print $1}')
        GIT_OWNER=$(stat -c '%U' .git)

        # Helper to run git command as owner or root
        run_git() {
            local cmd="$1"
            if [ "$USER" == "root" ] && [ "$GIT_OWNER" != "root" ]; then
                 su - "$GIT_OWNER" -c "cd \"$PWD\" && $cmd"
            else
                 eval "$cmd"
            fi
        }

        run_git "git checkout $CURRENT_GIT_BRANCH"

        if [[ "${GIT_FORCE_RESET,,}" == "true" ]]; then
            log_warn "FORCE RESET ENABLED: Resetting local changes to match origin/$CURRENT_GIT_BRANCH"
            run_git "git fetch --all"
            run_git "git reset --hard origin/$CURRENT_GIT_BRANCH"
        else
            run_git "git pull origin $CURRENT_GIT_BRANCH"
        fi

        CHECKSUM_AFTER=$(sha256sum "$0" | awk '{print $1}')

        if [ "$CHECKSUM_BEFORE" != "$CHECKSUM_AFTER" ]; then
            log_warn "INSTALLER SCRIPT UPDATED - RESTARTING..."
            exec "$0" --update --branch "$CURRENT_GIT_BRANCH"
        fi
    fi

    cp "$MAIN_SCRIPT" "$INSTALL_DIR/"
    if [ -f "requirements.txt" ]; then cp "requirements.txt" "$INSTALL_DIR/"; fi

    chown -R "$SERVICE_USER":"$SERVICE_GROUP" "$INSTALL_DIR"

    if [ -f "$INSTALL_DIR/requirements.txt" ]; then
        log_info "Updating Python dependencies..."
        su - "$SERVICE_USER" -c "$INSTALL_DIR/venv/bin/pip install --upgrade -r $INSTALL_DIR/requirements.txt"
    fi

    systemctl start "$SERVICE_NAME"
    log_info "Service restarted."

    if [ -n "$HEALTHCHECK_URL" ]; then
        wait_for_healthcheck "$HEALTHCHECK_URL"
    fi

    log_info "Upgrade complete."
}

do_restart() {
    log_header "PHASE: RESTART SERVICE"
    check_root
    manage_config

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_info "Restarting $SERVICE_NAME..."
        systemctl restart "$SERVICE_NAME"
        log_info "Service restarted successfully."
    else
        log_warn "Service $SERVICE_NAME is not currently running. Starting it..."
        systemctl start "$SERVICE_NAME"
        log_info "Service started successfully."
    fi

    if [ -n "$HEALTHCHECK_URL" ]; then
        wait_for_healthcheck "$HEALTHCHECK_URL"
    fi
}

do_uninstall_service() {
    log_header "PHASE: UNINSTALL SERVICE"
    check_root
    manage_config

    systemctl stop "$SERVICE_NAME" 2>/dev/null
    systemctl disable "$SERVICE_NAME" 2>/dev/null
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload

    get_input "Delete directory $INSTALL_DIR? (y/n)" "DELETE_DIR" "n"
    if [[ "${DELETE_DIR,,}" == "y" ]]; then
        if [ -f "$INSTALL_DIR/$SECRETS_FILE" ]; then
            log_warn "Deleting API Keys stored in $INSTALL_DIR/$SECRETS_FILE"
        fi
        rm -rf "$INSTALL_DIR"
        log_info "Directory removed."
    fi
    log_info "Uninstallation complete."
}

# --- Phase: Status & Logs ---

do_status() {
    log_header "PHASE: STATUS"
    manage_config

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_info "Service is ACTIVE."
    else
        log_warn "Service is INACTIVE."
    fi
    systemctl status "$SERVICE_NAME" --no-pager
}

do_logs() {
    log_header "PHASE: LOGS"
    manage_config

    log_info "Showing last 50 lines of logs. Press q to exit."
    journalctl -u "$SERVICE_NAME" -n 50 -f
}

# --- Menu / Argument Handler ---

show_menu() {
    echo "========================================"
    log_header "  Python Service Manager"
    echo "========================================"
    echo "1. Run Test"
    echo "2. Cleanup Test"
    echo "3. Install Service"
    echo "4. Upgrade Service (Update)"
    echo "5. Uninstall Service"
    echo "6. Restart Service"
    echo "7. Check Status"
    echo "8. View Logs"
    echo "9. Settings"
    echo "10. Exit"
    echo "========================================"

    get_input "Select an option" "MENU_CHOICE" ""

    case $MENU_CHOICE in
        1) do_test ;;
        2) do_test_cleanup ;;
        3) do_install ;;
        4) do_upgrade ;;
        5) do_uninstall_service ;;
        6) do_restart ;;
        7) do_status ;;
        8) do_logs ;;
        9) manage_config ;;
        10|exit) exit 0 ;;
        *) log_error "Invalid option" ;;
    esac
}

show_help() {
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  -u, --update    Pulls git changes, updates venv, and restarts service"
    echo "  -m, --main      Forces update using the 'main' git branch"
    echo "  -n, --newest    Forces update using the most recently updated local git branch"
    echo "  -c, --settings  Opens the configuration manager"
    echo "  -s, --status    Checks the status of the service"
    echo "  -l, --logs      Views the last 50 lines of logs"
    echo "  -r, --restart   Restarts the systemd service"
    echo "  -h, --help      Displays this help message"
    echo "  --test          Runs script locally in a temp venv (Testing Phase)"
    echo "  --cleanup-test  Removes temp venv and kills stray processes"
    echo "  --install       Deploys application to /opt and registers systemd service"
    echo "  --uninstall     Stops service, removes systemd unit, and deletes files"
}

# Entry Point
if [ $# -eq 0 ]; then
    show_menu
else
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--update|--upgrade)
                ACTION="update"
                shift
                ;;
            -m|--main)
                CURRENT_GIT_BRANCH="main"
                ACTION="update"
                shift
                ;;
            -n|--newest)
                if [ -d ".git" ]; then
                    NEWEST=$(git for-each-ref --sort=-committerdate refs/heads/ --format='%(refname:short)' | head -n 1)
                    CURRENT_GIT_BRANCH="${NEWEST:-main}"
                else
                    CURRENT_GIT_BRANCH="main"
                fi
                ACTION="update"
                shift
                ;;
            -c|--settings)
                ACTION="settings"
                shift
                ;;
            -s|--status)
                ACTION="status"
                shift
                ;;
            -l|--logs)
                ACTION="logs"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            --test)
                ACTION="test"
                shift
                ;;
            --cleanup-test)
                ACTION="cleanup-test"
                shift
                ;;
            --install)
                ACTION="install"
                shift
                ;;
            --uninstall)
                ACTION="uninstall"
                shift
                ;;
            --branch)
                CURRENT_GIT_BRANCH="$2"
                shift 2
                ;;
            -r|--restart)
                ACTION="restart"
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                show_menu
                exit 0
                ;;
        esac
    done

    # Execute Action
    case "$ACTION" in
        update)       do_upgrade ;;
        settings)     manage_config ;;
        status)       do_status ;;
        restart)      do_restart ;;
        logs)         do_logs ;;
        test)         do_test ;;
        cleanup-test) do_test_cleanup ;;
        install)      do_install ;;
        uninstall)    do_uninstall_service ;;
        *)            show_menu ;;
    esac
fi

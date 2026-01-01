#!/bin/bash

# ==============================================================================
# Mailuminati Guardian Installer
#
# This script checks for required dependencies and provides installation
# options for Mailuminati Guardian.
# It is designed to be run on modern Linux distributions.
#
# Note: All user-facing messages in this installer are intentionally in English.
# ==============================================================================

# --- Configuration ---
# Colors for beautiful output
COLOR_RESET='\033[0m'
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'

# --- Helper functions for logging ---
log_info() {
    echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $1"
}

log_success() {
    echo -e "${COLOR_GREEN}[OK]${COLOR_RESET} $1"
}

log_warning() {
    echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $1"
}

log_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $1"
}

# --- CLI options / feature toggles ---
# Defaults keep existing behavior.
ENABLE_RSPAMD_INTEGRATION=1
ENABLE_SPAMASSASSIN_INTEGRATION=1
ENABLE_MTA_FILTER_CHECK=1
OFFER_FILTER_INTEGRATION=1

show_help() {
    cat <<'EOF'
Mailuminati Guardian Installer

Usage:
  ./install.sh [options]

Options:
  --no-rspamd              Disable Rspamd integration (even if installed)
  --no-spamassassin        Disable SpamAssassin integration (even if installed)
  --no-filter-check        Do not warn if no mail filter is installed
  --no-filter-integration  Do not offer integration steps after startup
  -h, --help               Show this help

Environment variables (override defaults):
  ENABLE_RSPAMD_INTEGRATION=0|1
  ENABLE_SPAMASSASSIN_INTEGRATION=0|1
  ENABLE_MTA_FILTER_CHECK=0|1
  OFFER_FILTER_INTEGRATION=0|1
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --no-rspamd)
                ENABLE_RSPAMD_INTEGRATION=0
                ;;
            --no-spamassassin)
                ENABLE_SPAMASSASSIN_INTEGRATION=0
                ;;
            --no-filter-check)
                ENABLE_MTA_FILTER_CHECK=0
                ;;
            --no-filter-integration)
                OFFER_FILTER_INTEGRATION=0
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                log_info "Run: ./install.sh --help"
                exit 2
                ;;
        esac
        shift
    done
}

# --- Dependency check functions ---

# Generic function to check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Warn if running as root
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    log_warning "Running installer as root. This is not required."
fi

# 1. Check for Docker
check_docker() {
    log_info "Checking for Docker..."
    if command_exists docker; then
        log_success "Docker is installed."
        DOCKER_VERSION=$(docker --version)
        log_info " -> Version: $DOCKER_VERSION"
        return 0
    else
        log_error "Docker is not installed. It is required to run Mailuminati Guardian."
        log_info "Please visit https://docs.docker.com/engine/install/ for installation instructions."
        return 1
    fi
}

# 2. Check for Docker Compose
check_docker_compose() {
    log_info "Checking for Docker Compose..."
    if docker compose version &> /dev/null; then
        log_success "Docker Compose (v2+) is installed."
        return 0
    elif command_exists docker-compose; then
        log_success "Docker Compose (v1) is installed."
        log_warning "Consider upgrading to Docker Compose v2 for better integration."
        return 0
    else
        log_error "Docker Compose is not installed. It is required to manage the services."
        log_info "Please visit https://docs.docker.com/compose/install/ for installation instructions."
        return 1
    fi
}

# 3. Check for a mail filter (Rspamd or SpamAssassin)
check_mta_filter() {
    if [ "${ENABLE_MTA_FILTER_CHECK}" != "1" ]; then
        return 0
    fi
    if command_exists rspamd; then
        return 0
    elif command_exists spamassassin; then
        return 0
    else
        log_warning "No primary mail filter (Rspamd or SpamAssassin) found."
        log_info "Mailuminati Guardian is designed to work alongside one of them for optimal filtering."
        return 2 # Return a specific code for warning
    fi
}

# 4. Check for Dovecot (IMAP/POP3 server)
check_dovecot() {
    if command_exists dovecot; then
        return 0
    else
        log_warning "Dovecot is not found."
        log_info "If you handle mail reporting from mailboxes, Dovecot is recommended."
        return 2 # Return a specific code for warning
    fi
}

# 5. Check for Go (for building from source)
check_go() {
    log_info "Checking for Go programming language..."
    if command_exists go; then
        GO_VERSION=$(go version)
        log_success "Go is installed."
        log_info " -> Version: $GO_VERSION"
        return 0
    else
        log_warning "Go is not installed."
        log_info "Go is only required if you plan to build Mailuminati Guardian from source."
        return 2 # Return a specific code for warning
    fi
}

# 6. Check for Redis
check_redis() {
    log_info "Checking for Redis..."
    if command_exists redis-server || command_exists redis-cli; then
        log_success "Redis appears to be installed."
        return 0
    else
        log_warning "Redis is not found."
        log_info "Redis is required if you plan to run the application outside of Docker."
        return 2 # Return a specific code for warning
    fi
}

# --- Post-start verification & integration helpers ---

http_get() {
    local url="$1"
    if command_exists curl; then
        curl -fsS --max-time 2 "$url"
        return $?
    elif command_exists wget; then
        wget -qO- --timeout=2 "$url"
        return $?
    fi
    return 127
}

validate_status_json() {
    local json="$1"
    [[ "$json" =~ \"node_id\"[[:space:]]*:[[:space:]]*\"[^\"]+\" ]] || return 1
    [[ "$json" =~ \"current_seq\"[[:space:]]*:[[:space:]]*[0-9]+ ]] || return 1
    return 0
}

wait_for_status_ready() {
    local url="${1:-http://localhost:1133/status}"
    local timeout_s="${2:-30}"
    local deadline=$((SECONDS + timeout_s))
    local json=""

    if ! command_exists curl && ! command_exists wget; then
        log_warning "Cannot verify /status automatically (missing 'curl' or 'wget')."
        log_info "Please run: curl -sS ${url}"
        return 2
    fi

    log_info "Verifying service health via ${url} (timeout: ${timeout_s}s)..."
    while [ "$SECONDS" -lt "$deadline" ]; do
        json="$(http_get "$url" 2>/dev/null || true)"
        if [ -n "$json" ] && validate_status_json "$json"; then
            log_success "Service health check OK (/status returned node_id and current_seq)."
            log_info " -> ${json}"
            return 0
        fi
        sleep 1
    done

    log_warning "Service started, but /status did not return a valid payload in time."
    log_info "Expected keys: node_id, current_seq"
    return 1
}

first_existing_dir() {
    for d in "$@"; do
        if [ -n "$d" ] && [ -d "$d" ]; then
            echo "$d"
            return 0
        fi
    done
    return 1
}

detect_rspamd_paths() {
    RSPAMD_CONF_ROOT=""
    RSPAMD_LOCAL_D=""
    RSPAMD_OVERRIDE_D=""
    RSPAMD_LUA_DIR=""

    # Common distro paths
    RSPAMD_CONF_ROOT="$(first_existing_dir \
        "/etc/rspamd" \
        "/usr/local/etc/rspamd" \
        "/opt/rspamd/etc/rspamd" \
    )" || true

    if [ -n "$RSPAMD_CONF_ROOT" ]; then
        RSPAMD_LOCAL_D="$(first_existing_dir "${RSPAMD_CONF_ROOT}/local.d" "${RSPAMD_CONF_ROOT}/override.d")" || true
        RSPAMD_OVERRIDE_D="$(first_existing_dir "${RSPAMD_CONF_ROOT}/override.d")" || true
        RSPAMD_LUA_DIR="$(first_existing_dir "${RSPAMD_CONF_ROOT}/lua")" || true
    fi

    # Common share paths for Lua (rules/plugins)
    if [ -z "$RSPAMD_LUA_DIR" ]; then
        RSPAMD_LUA_DIR="$(first_existing_dir \
            "/usr/share/rspamd/lua" \
            "/usr/local/share/rspamd/lua" \
            "/opt/rspamd/share/rspamd/lua" \
        )" || true
    fi

    # Final fallback
    [ -z "$RSPAMD_LOCAL_D" ] && RSPAMD_LOCAL_D="$RSPAMD_CONF_ROOT/local.d"
    [ -z "$RSPAMD_OVERRIDE_D" ] && RSPAMD_OVERRIDE_D="$RSPAMD_CONF_ROOT/override.d"
}

detect_spamassassin_paths() {
    SA_CONF_DIR=""
    SA_PLUGIN_DIR=""

    SA_CONF_DIR="$(first_existing_dir \
        "/etc/mail/spamassassin" \
        "/etc/spamassassin" \
        "/usr/local/etc/mail/spamassassin" \
        "/usr/local/etc/spamassassin" \
    )" || true

    # Try to locate Mail::SpamAssassin installation path and infer Plugin dir
    if command_exists perl; then
        local sa_pm=""
        sa_pm="$(perl -MMail::SpamAssassin -e 'print $INC{"Mail/SpamAssassin.pm"}' 2>/dev/null || true)"
        if [ -n "$sa_pm" ]; then
            # .../Mail/SpamAssassin.pm -> .../Mail/SpamAssassin/Plugin
            local base="${sa_pm%/SpamAssassin.pm}"
            SA_PLUGIN_DIR="$(first_existing_dir "${base}/SpamAssassin/Plugin")" || true
        fi
    fi

    # Common plugin install paths
    if [ -z "$SA_PLUGIN_DIR" ]; then
        SA_PLUGIN_DIR="$(first_existing_dir \
            "/usr/share/perl5/Mail/SpamAssassin/Plugin" \
            "/usr/local/share/perl5/Mail/SpamAssassin/Plugin" \
            "/usr/share/perl/5.*/Mail/SpamAssassin/Plugin" \
        )" || true
    fi
}

confirm_yes_no() {
    local prompt="$1"
    local default_answer="$2" # y|n

    local suffix="[y/N]"
    [ "$default_answer" = "y" ] && suffix="[Y/n]"

    local answer=""
    read -r -p "${prompt} ${suffix}: " answer
    answer="${answer:-$default_answer}"
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

configure_rspamd_integration() {
    detect_rspamd_paths

    local sudo_cmd=""
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        sudo_cmd="sudo"
    fi

    local suggested_conf_root="${RSPAMD_CONF_ROOT:-/etc/rspamd}"
    local rspamd_conf_root=""

    echo -e "\n--------------------------------------------------"
    log_info "Rspamd integration (interactive)"
    log_info "Detected config root (best-effort): ${suggested_conf_root}"
    echo "--------------------------------------------------"

    while true; do
        read -r -p "Rspamd configuration root [${suggested_conf_root}]: " rspamd_conf_root
        rspamd_conf_root="${rspamd_conf_root:-$suggested_conf_root}"

        echo
        log_info "Selected: ${rspamd_conf_root}"
        if confirm_yes_no "Use this path" "y"; then
            break
        fi
        suggested_conf_root="$rspamd_conf_root"
    done

    if [ ! -d "$rspamd_conf_root" ]; then
        log_warning "Rspamd config directory does not exist: $rspamd_conf_root"
        if ! confirm_yes_no "Create it" "n"; then
            log_error "Cannot proceed without a valid Rspamd config directory."
            return 1
        fi
        if ! $sudo_cmd mkdir -p "$rspamd_conf_root"; then
            log_error "Failed to create: $rspamd_conf_root"
            return 1
        fi
        log_success "Created: $rspamd_conf_root"
    fi

    # Ensure local lua directory exists (even if not provided by default)
    local rspamd_local_lua_dir="${rspamd_conf_root}/lua"
    if ! $sudo_cmd mkdir -p "$rspamd_local_lua_dir"; then
        log_error "Failed to create: $rspamd_local_lua_dir"
        return 1
    fi

    # Ensure local.d exists for .conf drop-ins
    local rspamd_local_d_dir="${rspamd_conf_root}/local.d"
    if ! $sudo_cmd mkdir -p "$rspamd_local_d_dir"; then
        log_error "Failed to create: $rspamd_local_d_dir"
        return 1
    fi

    local rspamd_local_lua_file="${rspamd_conf_root}/rspamd.local.lua"
    if [ ! -f "$rspamd_local_lua_file" ]; then
        log_info "Creating ${rspamd_local_lua_file}"
        if ! cat <<EOF | $sudo_cmd tee "$rspamd_local_lua_file" >/dev/null
-- Local overrides for Rspamd (Mailuminati Guardian)
EOF
        then
            log_error "Failed to create: $rspamd_local_lua_file"
            return 1
        fi
        log_success "Created: $rspamd_local_lua_file"
    fi

    # Ensure Mailuminati module is loaded
    local dofile_line="dofile(\"${rspamd_local_lua_dir}/mailuminati.lua\")"
    if grep -Eq 'dofile\([^\)]*mailuminati\.lua' "$rspamd_local_lua_file" 2>/dev/null; then
        log_success "Mailuminati dofile already present in rspamd.local.lua"
    else
        log_info "Adding Mailuminati dofile to rspamd.local.lua"
        if ! printf "\n%s\n" "$dofile_line" | $sudo_cmd tee -a "$rspamd_local_lua_file" >/dev/null; then
            log_error "Failed to update: $rspamd_local_lua_file"
            return 1
        fi
        log_success "Updated: $rspamd_local_lua_file"
    fi

    # Copy (overwrite) the Mailuminati lua module shipped with Guardian
    local script_dir
    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    local lua_src="${script_dir}/Rspamd/mailuminati.lua"
    local lua_dst="${rspamd_local_lua_dir}/mailuminati.lua"

    if [ ! -f "$lua_src" ]; then
        log_error "Cannot find source lua module: $lua_src"
        log_info "Expected it inside the Guardian install directory under: Rspamd/mailuminati.lua"
        return 1
    fi

    if command_exists install; then
        if ! $sudo_cmd install -m 0644 "$lua_src" "$lua_dst"; then
            log_error "Failed to install: $lua_dst"
            return 1
        fi
    else
        if ! $sudo_cmd cp -f "$lua_src" "$lua_dst"; then
            log_error "Failed to copy: $lua_dst"
            return 1
        fi
    fi
    log_success "Installed: $lua_dst"

    # Validate Rspamd configuration
    log_info "Validating Rspamd configuration..."
    local config_ok=0
    if command_exists rspamadm; then
        if rspamadm configtest -c "$rspamd_conf_root" >/dev/null 2>&1; then
            config_ok=1
        elif rspamadm configtest >/dev/null 2>&1; then
            config_ok=1
        fi
    elif command_exists rspamd; then
        # Best-effort fallback
        if rspamd -t -c "$rspamd_conf_root" >/dev/null 2>&1; then
            config_ok=1
        elif rspamd -t >/dev/null 2>&1; then
            config_ok=1
        fi
    fi

    if [ "$config_ok" != "1" ]; then
        log_error "Rspamd config test failed (or could not be run). Not reloading service."
        log_info "Try manually: sudo rspamadm configtest -c ${rspamd_conf_root}"
        return 1
    fi
    log_success "Rspamd configuration looks valid."

    # Reload Rspamd
    log_info "Reloading Rspamd service..."
    if command_exists systemctl; then
        if $sudo_cmd systemctl reload rspamd >/dev/null 2>&1; then
            log_success "Rspamd reloaded (systemctl reload)."
            return 0
        fi
        log_warning "Reload failed; trying restart (systemctl restart)."
        if $sudo_cmd systemctl restart rspamd >/dev/null 2>&1; then
            log_success "Rspamd restarted (systemctl restart)."
            return 0
        fi
    elif command_exists service; then
        if $sudo_cmd service rspamd reload >/dev/null 2>&1; then
            log_success "Rspamd reloaded (service reload)."
            return 0
        fi
        log_warning "Reload failed; trying restart (service restart)."
        if $sudo_cmd service rspamd restart >/dev/null 2>&1; then
            log_success "Rspamd restarted (service restart)."
            return 0
        fi
    fi

    log_warning "Could not automatically reload Rspamd. Please reload it manually."
    log_info "Examples: sudo systemctl reload rspamd  OR  sudo systemctl restart rspamd"
    return 2
}

print_spamassassin_integration_instructions() {
    detect_spamassassin_paths

    echo -e "\n--------------------------------------------------"
    log_info "SpamAssassin integration (manual steps):"
    log_info "Detected paths (best-effort):"
    echo " - SA_CONF_DIR:    ${SA_CONF_DIR:-<unknown>}"
    echo " - SA_PLUGIN_DIR:  ${SA_PLUGIN_DIR:-<unknown>}"
    echo
    echo "1) Prefer placing your Mailuminati .cf rules in: ${SA_CONF_DIR:-/etc/mail/spamassassin}"
    echo "2) If you ship a custom Perl plugin, place it in: ${SA_PLUGIN_DIR:-<perl site/lib>/Mail/SpamAssassin/Plugin}"
    echo "3) Add a custom check (plugin or wrapper) that submits the message (MIME) to: http://127.0.0.1:1133/analyze"
    echo "4) If response action==spam: add a rule hit and score accordingly."
    echo "5) Optionally forward user feedback to: http://127.0.0.1:1133/report"
    echo "6) Restart spamd/spamassassin service."
    log_info "Note: This installer currently prints guidance only (no files are written)."
    echo -e "--------------------------------------------------\n"
}

offer_filter_integration() {
    if [ "${OFFER_FILTER_INTEGRATION}" != "1" ]; then
        log_info "Skipping mail filter integration (disabled by option/env)."
        return 0
    fi

    local has_rspamd=0
    local has_sa=0
        if [ "${ENABLE_RSPAMD_INTEGRATION}" = "1" ] && command_exists rspamd; then
        has_rspamd=1
    fi
    if [ "${ENABLE_SPAMASSASSIN_INTEGRATION}" = "1" ] && command_exists spamassassin; then
        has_sa=1
    fi

    command_exists rspamd && has_rspamd=1
    command_exists spamassassin && has_sa=1

    if [ "$has_rspamd" != "1" ] && [ "$has_sa" != "1" ]; then
        log_info "No supported mail filter detected (rspamd/spamassassin). Skipping integration guidance."
        return 0
    fi

    echo -e "\n--------------------------------------------------"
    log_info "Optional: install mail filter integration now?"
    echo "--------------------------------------------------"

    local default_choice="3"
    if [ "$has_rspamd" = "1" ]; then
        echo "1) Rspamd integration (recommended)"
        default_choice="1"
    else
        echo "1) Rspamd integration (unavailable)"
    fi

    if [ "$has_sa" = "1" ]; then
        echo "2) SpamAssassin integration"
        [ "$default_choice" = "3" ] && default_choice="2"
    else
        echo "2) SpamAssassin integration (unavailable)"
    fi

    echo "3) Skip"

    while true; do
        read -r -p "Enter your choice [${default_choice}]: " choice
        choice=${choice:-$default_choice}
        case "$choice" in
            1)
                [ "$has_rspamd" = "1" ] || { log_error "Rspamd is not available on this system."; continue; }
                configure_rspamd_integration
                break
                ;;
            2)
                [ "$has_sa" = "1" ] || { log_error "SpamAssassin is not available on this system."; continue; }
                print_spamassassin_integration_instructions
                break
                ;;
            3)
                log_info "Skipping integration."
                break
                ;;
            *)
                log_error "Invalid option: $choice"
                ;;
        esac
    done
}

post_start_flow() {
    wait_for_status_ready "http://localhost:1133/status" 30 || true
    offer_filter_integration
}

# --- Main Installation Logic ---

show_installation_options() {
    echo -e "\n--------------------------------------------------"
    log_info "Available installation methods:"
    if [ "$docker_possible" = "1" ] && [ "$source_possible" = "1" ]; then
        log_success "Docker Compose and Standalone build from source"
    elif [ "$docker_possible" = "1" ]; then
        log_success "Docker Compose"
    elif [ "$source_possible" = "1" ]; then
        log_success "Build Standalone from source"
    else
        log_error "None"
    fi

    log_info "Choose an installation method for Mailuminati Guardian:"
    echo "--------------------------------------------------"

    if [ "$docker_possible" = "1" ]; then
        echo "1) Install with Docker (Recommended)"
    else
        echo "1) Install with Docker (Unavailable)"
    fi

    if [ "$source_possible" = "1" ]; then
        echo "2) Build Standalone from source (requires Go)"
    else
        echo "2) Build Standalone from source (Unavailable)"
    fi
    echo "3) Exit"

    while true; do
        read -r -p "Enter your choice [${default_choice}]: " choice
        choice=${choice:-$default_choice}

        case "$choice" in
            1)
                if [ "$docker_possible" != "1" ]; then
                    log_error "Docker Compose install is not available on this system."
                    continue
                fi
                log_info "Proceeding with Docker installation..."
                if [ -f "docker-compose.yaml" ]; then
                    log_info "Found 'docker-compose.yaml'."

                    log_info "Ensuring 'Mailuminati' network exists..."
                    if ! docker network inspect Mailuminati &> /dev/null; then
                        log_info "Network 'Mailuminati' not found. Creating it..."
                        if docker network create Mailuminati; then
                            log_success "Network 'Mailuminati' created."
                        else
                            log_error "Failed to create 'Mailuminati' network."
                            break
                        fi
                    else
                        log_success "Network 'Mailuminati' already exists."
                    fi

                    log_info "Building and starting services with Docker Compose..."
                    if docker compose up -d --build; then
                        log_success "Mailuminati Guardian has been started successfully."
                        log_success "The project is now listening on port 1133."
                        post_start_flow
                    else
                        log_error "Failed to start services with Docker Compose. Please check the output above."
                    fi
                else
                    log_error "'docker-compose.yaml' not found in the current directory."
                    log_info "Please place the file in the same directory as the installer or run the installer from the correct directory."
                fi
                break
                ;;
            2)
                if [ "$source_possible" != "1" ]; then
                    log_error "Source build install is not available on this system."
                    continue
                fi
                if ! command_exists go; then
                    log_error "Go is not installed. Cannot build Standalone from source."
                    log_info "Please install Go or choose the Docker installation method."
                elif ! command_exists redis-server && ! command_exists redis-cli; then
                    log_error "Redis is not installed. Cannot proceed with Standalone build."
                    log_info "Please install Redis or choose the Docker installation method."
                else
                    # --- TLSH binary check and build logic ---
                    TLSH_BIN_PATH="${TLSH_BIN:-/usr/local/bin/tlsh}"
                    if [ -x "$TLSH_BIN_PATH" ]; then
                        log_success "TLSH binary found at $TLSH_BIN_PATH."
                    else
                        log_warning "TLSH binary not found at $TLSH_BIN_PATH. Attempting to build it."
                        for dep in git cmake make g++; do
                            if ! command_exists $dep; then
                                log_error "$dep is required to build TLSH but is not installed."
                                log_info "Please install $dep and re-run the installer."
                                exit 1
                            fi
                        done
                        TMP_BUILD_DIR="/tmp/tlsh_build_$$"
                        mkdir -p "$TMP_BUILD_DIR"
                        cd "$TMP_BUILD_DIR"
                        log_info "Cloning TLSH repository..."
                        if git clone https://github.com/trendmicro/tlsh.git; then
                            cd tlsh
                            chmod +x ./make.sh
                            log_info "Building TLSH..."
                            if ./make.sh; then
                                if [ -f bin/tlsh ]; then
                                    sudo cp bin/tlsh /usr/local/bin/tlsh
                                    log_success "TLSH binary built and installed to /usr/local/bin/tlsh."
                                else
                                    log_error "TLSH build succeeded but binary not found."
                                    exit 1
                                fi
                            else
                                log_error "TLSH build failed."
                                exit 1
                            fi
                        else
                            log_error "Failed to clone TLSH repository."
                            exit 1
                        fi
                        cd - > /dev/null
                        rm -rf "$TMP_BUILD_DIR"
                    fi
                    # --- End TLSH logic ---
                    if [ -f "mi_guardian/main.go" ]; then
                        log_info "Initializing Go module in mi_guardian..."
                        cd mi_guardian
                        go mod init mailuminati-guardian || log_info "Go module already initialized."
                        log_info "Tidying Go modules..."
                        go mod tidy
                        log_info "Building the binary..."
                        if go build; then
                            log_success "Build complete. The binary is available in the mi_guardian directory."
                            # Move binary to /opt/Mailuminati
                            sudo mkdir -p /opt/Mailuminati
                            sudo mv mi_guardian /opt/Mailuminati/mi_guardian
                            log_success "Binary moved to /opt/Mailuminati/mi_guardian."
                            # Create system user if not exists
                            if ! id -u mailuminati &>/dev/null; then
                                sudo useradd --system --no-create-home --shell /usr/sbin/nologin mailuminati
                                log_success "System user 'mailuminati' created."
                            else
                                log_info "System user 'mailuminati' already exists."
                            fi
                            # Set ownership
                            sudo chown -R mailuminati:mailuminati /opt/Mailuminati
                            log_success "Ownership of /opt/Mailuminati set to 'mailuminati'."
                            # Create systemd service
                            SERVICE_FILE="/etc/systemd/system/mailuminati-guardian.service"
                            sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Mailuminati Guardian Service
After=network.target

[Service]
Type=simple
ExecStart=/opt/Mailuminati/mi_guardian
Restart=always
RestartSec=5
User=mailuminati

[Install]
WantedBy=multi-user.target
EOF
                            log_success "Systemd service file created at $SERVICE_FILE (running as 'mailuminati')."
                            # Reload, enable and start the service
                            sudo systemctl daemon-reload
                            sudo systemctl enable mailuminati-guardian
                            sudo systemctl restart mailuminati-guardian
                            log_success "Mailuminati Guardian service started and enabled."
                            log_success "The project is now listening on port 1133."
                            post_start_flow
                        else
                            log_error "Build failed. Please check the Go output above."
                        fi
                        cd ..
                    else
                        log_error "No 'main.go' file found in the 'mi_guardian' directory. Please check your source tree."
                    fi
                fi
                break
                ;;
            3)
                log_info "Installation aborted."
                break
                ;;
            *)
                log_error "Invalid option: $choice"
                ;;
        esac
    done
}


main() {
    echo -e "=================================================="
    echo -e " Mailuminati Guardian Dependency Checker"
    echo -e "=================================================="

    # Allow env vars to override defaults
    ENABLE_RSPAMD_INTEGRATION="${ENABLE_RSPAMD_INTEGRATION:-1}"
    ENABLE_SPAMASSASSIN_INTEGRATION="${ENABLE_SPAMASSASSIN_INTEGRATION:-1}"
    ENABLE_MTA_FILTER_CHECK="${ENABLE_MTA_FILTER_CHECK:-1}"
    OFFER_FILTER_INTEGRATION="${OFFER_FILTER_INTEGRATION:-1}"

    parse_args "$@"

    # Optional environment hints (only warn when missing)
    check_mta_filter
    check_dovecot

    # Detect availability without spamming OK details
    docker_possible=0
    if command_exists docker; then
        if docker compose version &> /dev/null || command_exists docker-compose; then
            if [ -f "docker-compose.yaml" ]; then
                docker_possible=1
            fi
        fi
    fi

    source_possible=0
    if command_exists go; then
        if command_exists redis-server || command_exists redis-cli; then
            source_possible=1
        fi
    fi

    # Default choice: Docker if possible, otherwise source (when Docker/Compose missing)
    default_choice=3
    if [ "$docker_possible" = "1" ]; then
        default_choice=1
    elif [ "$source_possible" = "1" ]; then
        default_choice=2
    fi

    # If nothing is possible, explain briefly why (no OK details)
    if [ "$docker_possible" != "1" ] && [ "$source_possible" != "1" ]; then
        echo -e "\n--------------------------------------------------"
        log_error "No installation method is possible with the current dependencies."
        log_info "For Docker Compose: install Docker + Docker Compose and run from a folder containing docker-compose.yaml."
        log_info "For Standalone build from source: install Go + Redis."
        echo -e "--------------------------------------------------"
        exit 1
    fi

    show_installation_options "$docker_possible" "$source_possible" "$default_choice"
    
    exit 0
}

# --- Run the script ---
main "$@"

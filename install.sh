#!/bin/bash

# Mailuminati Guardian 
# Copyright (C) 2025 Simon Bressier
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, version 3.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# ==============================================================================
# Mailuminati Guardian Installer
#
# This script checks for required dependencies and provides installation
# options for Mailuminati Guardian.
# It is designed to be run on modern Linux distributions.
# ==============================================================================

# Version
GUARDIAN_VERSION="0.4.5"

# Directory where this installer resides (so relative paths work even if run from elsewhere)
INSTALLER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Absolute path to compose file (so Docker can be launched from anywhere)
COMPOSE_FILE="${INSTALLER_DIR}/docker-compose.yaml"

# Source split files
source "${INSTALLER_DIR}/install/utils.sh"
source "${INSTALLER_DIR}/install/cli.sh"
source "${INSTALLER_DIR}/install/checks.sh"
source "${INSTALLER_DIR}/install/integration.sh"
source "${INSTALLER_DIR}/install/install_docker.sh"
source "${INSTALLER_DIR}/install/install_source.sh"

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
        echo "2) Build Standalone from source (requires Go, Redis)"
    else
        echo "2) Build Standalone from source (Unavailable)"
    fi
    echo "3) Configure Integrations only (Skip install)"
    echo "4) Exit"

    while true; do
        read -r -p "Enter your choice [${default_choice}]: " choice
        choice=${choice:-$default_choice}

        case "$choice" in
            1)
                install_docker
                break
                ;;
            2)
                install_source
                break
                ;;
            3)
                log_info "Skipping installation, proceeding to integration setup..."
                post_start_flow
                break
                ;;
            4)
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

    # Ensure we run from the project root (relative paths: mi_guardian/, docker-compose.yaml, etc.)
    if ! cd "$INSTALLER_DIR"; then
        log_error "Failed to change directory to installer location: $INSTALLER_DIR"
        exit 1
    fi

    # Allow env vars to override defaults
    ENABLE_RSPAMD_INTEGRATION="${ENABLE_RSPAMD_INTEGRATION:-1}"
    ENABLE_SPAMASSASSIN_INTEGRATION="${ENABLE_SPAMASSASSIN_INTEGRATION:-1}"
    ENABLE_MTA_FILTER_CHECK="${ENABLE_MTA_FILTER_CHECK:-1}"
    OFFER_FILTER_INTEGRATION="${OFFER_FILTER_INTEGRATION:-1}"

    parse_args "$@"

    # Optional: Verify external Redis connectivity if specified
    if [ -n "$REDIS_HOST" ]; then
        if ! check_redis_connectivity "$REDIS_HOST" "$REDIS_PORT"; then
             log_error "Redis connectivity check failed. Aborting."
             exit 1
        fi
    fi

    # Check if Guardian is already running with the same version
    log_info "Checking for existing Mailuminati Guardian instance..."
    local check_url="http://localhost:12421/status"
    local running_version=""
    local json_payload=""

    if command_exists curl || command_exists wget; then
        json_payload="$(http_get "$check_url" 2>/dev/null || true)"
    fi

    if [ -n "$json_payload" ]; then
         running_version=$(echo "$json_payload" | grep -o '"version":[[:space:]]*"[^"]*"' | sed 's/"version":[[:space:]]*"//;s/"//')
    fi

    if [ -n "$running_version" ]; then
        if [ "$running_version" = "$GUARDIAN_VERSION" ]; then
            log_success "Mailuminati Guardian is already running version $running_version matching installer version."
            log_info "Skipping core installation."
            log_info "Proceeding directly to integration configuration..."
            post_start_flow
            exit 0
        else
            log_info "Found running Guardian version $running_version. Installer version is $GUARDIAN_VERSION."
        fi
    fi

    init_docker_sudo

    # Optional environment hints (only warn when missing)
    check_mta_filter
    check_dovecot

    # Detect availability without spamming OK details
    docker_possible=0
    if command_exists docker; then
        if $DOCKER_SUDO docker compose version &> /dev/null || command_exists docker-compose; then
            if [ -f "$COMPOSE_FILE" ]; then
                docker_possible=1
            fi
        fi
    fi

    source_possible=0
    if command_exists go; then
        if (command_exists redis-server || command_exists redis-cli); then
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

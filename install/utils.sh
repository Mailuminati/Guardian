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

# Generic function to check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

docker_compose_v2_available() {
    $DOCKER_SUDO docker compose version &> /dev/null
}

docker_needs_sudo() {
    docker info >/dev/null 2>&1 && return 1
    docker ps >/dev/null 2>&1 && return 1
    return 0
}

# Function to detect and select bind address
select_bind_address() {
    {
        echo -e "\n--------------------------------------------------"
        log_info "Network Configuration: Select interface to listen on"
        echo "--------------------------------------------------"
        
        local ips=()
        local i=1
        
        # Defaults
        echo "1) Localhost only (127.0.0.1) [Default - Most Secure]"
        ips+=("127.0.0.1")
        
        echo "2) All interfaces (0.0.0.0) [Public/Internet exposure]"
        ips+=("0.0.0.0")

        # Detect other IPs
        if command_exists ip; then
            while read -r line; do
                local ip=$(echo "$line" | awk '{print $4}' | cut -d/ -f1)
                local dev=$(echo "$line" | awk '{print $2}')
                if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ]; then
                     echo "$((i+2))) Detected: $ip ($dev)"
                     ips+=("$ip")
                     ((i++))
                fi
            done < <(ip -o -4 addr list)
        
        elif command_exists ifconfig; then
            # Simple loop for macOS (BSD style ifconfig)
            # Find lines starting with identifier, then look for inet
            local current_iface=""
            while read -r line; do
                if [[ "$line" =~ ^[a-zA-Z0-9]+: ]]; then
                    current_iface=$(echo "$line" | cut -d: -f1)
                fi
                if [[ "$line" =~ inet\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
                    local ip="${BASH_REMATCH[1]}"
                    if [ "$ip" != "127.0.0.1" ]; then
                       echo "$((i+2))) Detected: $ip ($current_iface)"
                       ips+=("$ip")
                       ((i++))
                    fi
                fi
            done < <(ifconfig)

        elif command_exists hostname; then
            # Fallback
            local simple_ips=$(hostname -I 2>/dev/null) 
             if [ -n "$simple_ips" ]; then
                for ip in $simple_ips; do
                    if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ]; then
                        echo "$((i+2))) Detected: $ip"
                        ips+=("$ip")
                        ((i++))
                    fi
                done
            fi
        fi
    } >&2

    local choice
    local selected_ip
    
    while true; do
        # Prompt to stderr
        read -r -p "Select an option [1]: " choice 
        choice=${choice:-1}
        
        # Check if choice is numeric
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
             local index=$((choice-1))
             if [ $index -ge 0 ] && [ $index -lt ${#ips[@]} ]; then
                 selected_ip="${ips[$index]}"
                 break
             fi
        fi
        log_error "Invalid selection. Please try again." >&2
    done

    echo "$selected_ip"
}

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
    local url="${1:-http://localhost:12421/status}"
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

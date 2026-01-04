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

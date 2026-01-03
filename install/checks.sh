#!/bin/bash

# --- Dependency check functions ---

init_docker_sudo() {
    DOCKER_SUDO=""
    if command_exists docker && [ "${EUID:-$(id -u)}" -ne 0 ] && docker_needs_sudo; then
        if command_exists sudo; then
            DOCKER_SUDO="sudo"
            log_warning "Docker daemon access seems to require sudo on this system."
            log_info "Tip: to avoid sudo, add your user to the 'docker' group and re-login."
        else
            log_warning "Docker daemon access seems restricted (permission issue), and 'sudo' is not available."
        fi
    fi
}

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
    if $DOCKER_SUDO docker compose version &> /dev/null; then
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
        # Check for sievec (Dovecot Sieve)
        if ! command_exists sievec; then
            log_warning "Dovecot is installed, but 'sievec' command is missing."
            log_info "This usually means the 'dovecot-sieve' or 'dovecot-pigeonhole' package is missing."
            
            if [ -f /etc/debian_version ]; then
                log_info "On Debian/Ubuntu, try: sudo apt install dovecot-sieve dovecot-managesieved"
            elif [ -f /etc/redhat-release ]; then
                log_info "On RHEL/CentOS, try: sudo dnf install dovecot-pigeonhole"
            elif [ -f /etc/alpine-release ]; then
                log_info "On Alpine, try: sudo apk add dovecot-pigeonhole-plugin"
            else
                log_info "Please install the Dovecot Sieve/Pigeonhole plugin for your distribution."
            fi
            return 2
        fi
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

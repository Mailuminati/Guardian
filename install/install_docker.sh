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

install_docker() {
    if [ "$docker_possible" != "1" ]; then
        log_error "Docker Compose install is not available on this system."
        return 1
    fi
    log_info "Proceeding with Docker installation..."
    if [ -f "$COMPOSE_FILE" ]; then
        log_info "Found '$COMPOSE_FILE'."

        log_info "Ensuring 'Mailuminati' network exists..."
        if ! $DOCKER_SUDO docker network inspect Mailuminati &> /dev/null; then
            log_info "Network 'Mailuminati' not found. Creating it..."
            if $DOCKER_SUDO docker network create Mailuminati; then
                log_success "Network 'Mailuminati' created."
            else
                log_error "Failed to create 'Mailuminati' network."
                return 1
            fi
        else
            log_success "Network 'Mailuminati' already exists."
        fi

        log_info "Building and starting services with Docker Compose..."
        
        # Generate .env file for Docker Compose
        echo "REDIS_HOST=${REDIS_HOST:-mailuminati-redis}" > "${INSTALLER_DIR}/.env"
        echo "REDIS_PORT=${REDIS_PORT:-6379}" >> "${INSTALLER_DIR}/.env"
        
        # Binding option
        local selected_bind_ip
        selected_bind_ip=$(select_bind_address)
        echo "GUARDIAN_BIND_ADDR=${selected_bind_ip}" >> "${INSTALLER_DIR}/.env"
        log_info "Configuration saved: Guardian will listen on ${selected_bind_ip}:12421"

        # Image Analysis Option
        echo -e "\n--------------------------------------------------"
        log_info "Experimental Feature: Image Analysis"
        echo "This feature downloads and hashes images from emails with low text content."
        echo "It connects to external servers to retrieve images, which may trigger tracking pixels."
        echo "--------------------------------------------------"
        local enable_img="false"
        if confirm_yes_no "Enable Image Analysis?" "n"; then
            enable_img="true"
            log_info "Image Analysis ENABLED."
        else
            log_info "Image Analysis DISABLED."
        fi
        echo "MI_ENABLE_IMAGE_ANALYSIS=${enable_img}" >> "${INSTALLER_DIR}/.env"
        
        local bind_ip="${selected_bind_ip}"
        
        # Fallback to localhost for curl check if binding to 0.0.0.0
        if [ "$bind_ip" == "0.0.0.0" ]; then
             bind_ip="127.0.0.1"
        fi

        if docker_compose_v2_available; then
            compose_up_ok=0
            # If REDIS_HOST is specified and differs from default "mailuminati-redis", assume external Redis and only start mi-guardian
            if [ -n "$REDIS_HOST" ] && [ "$REDIS_HOST" != "mailuminati-redis" ]; then
                log_info "External Redis specified ($REDIS_HOST). Launching only mi-guardian service."
                $DOCKER_SUDO docker compose -f "$COMPOSE_FILE" --project-directory "$INSTALLER_DIR" up -d --build mi-guardian && compose_up_ok=1
            else
                $DOCKER_SUDO docker compose -f "$COMPOSE_FILE" --project-directory "$INSTALLER_DIR" up -d --build && compose_up_ok=1
            fi
        else
            compose_up_ok=0
             if [ -n "$REDIS_HOST" ] && [ "$REDIS_HOST" != "mailuminati-redis" ]; then
                log_info "External Redis specified ($REDIS_HOST). Launching only mi-guardian service."
                $DOCKER_SUDO docker-compose -f "$COMPOSE_FILE" up -d --build mi-guardian && compose_up_ok=1
            else
                $DOCKER_SUDO docker-compose -f "$COMPOSE_FILE" up -d --build && compose_up_ok=1
            fi
        fi

        if [ "$compose_up_ok" = "1" ]; then
            log_success "Mailuminati Guardian has been started successfully."
            log_success "The project is now listening on port 12421."
            post_start_flow
        else
            log_error "Failed to start services with Docker Compose. Please check the output above."
        fi
    else
        log_error "Cannot find compose file: $COMPOSE_FILE"
        log_info "Please run the installer from the Guardian project root, or ensure docker-compose.yaml exists next to install.sh."
    fi
}

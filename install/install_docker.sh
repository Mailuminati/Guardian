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
        echo "REDIS_HOST=${REDIS_HOST:-mi-redis}" > "${INSTALLER_DIR}/.env"
        echo "REDIS_PORT=${REDIS_PORT:-6379}" >> "${INSTALLER_DIR}/.env"
        
        if docker_compose_v2_available; then
            compose_up_ok=0
            $DOCKER_SUDO docker compose -f "$COMPOSE_FILE" --project-directory "$INSTALLER_DIR" up -d --build && compose_up_ok=1
        else
            compose_up_ok=0
            $DOCKER_SUDO docker-compose -f "$COMPOSE_FILE" up -d --build && compose_up_ok=1
        fi

        if [ "$compose_up_ok" = "1" ]; then
            log_success "Mailuminati Guardian has been started successfully."
            log_success "The project is now listening on port 1133."
            post_start_flow
        else
            log_error "Failed to start services with Docker Compose. Please check the output above."
        fi
    else
        log_error "Cannot find compose file: $COMPOSE_FILE"
        log_info "Please run the installer from the Guardian project root, or ensure docker-compose.yaml exists next to install.sh."
    fi
}

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

install_source() {
    if [ "$source_possible" != "1" ]; then
        log_error "Source build install is not available on this system."
        return 1
    fi
    if ! command_exists go; then
        log_error "Go is not installed. Cannot build Standalone from source."
        log_info "Please install Go or choose the Docker installation method."
    elif ! command_exists redis-server && ! command_exists redis-cli; then
        log_error "Redis is not installed. Cannot proceed with Standalone build."
        log_info "Please install Redis or choose the Docker installation method."
    else
        if [ -f "${INSTALLER_DIR}/mi_guardian/main.go" ]; then
            log_info "Initializing Go module in mi_guardian..."
            pushd "${INSTALLER_DIR}/mi_guardian" >/dev/null || { log_error "Failed to enter ${INSTALLER_DIR}/mi_guardian"; exit 1; }
            go mod init mailuminati-guardian || log_info "Go module already initialized."
            log_info "Tidying Go modules..."
            go mod tidy
            log_info "Building the binary..."
            started_ok=0
            if go build; then
                log_success "Build complete. The binary is available in the mi_guardian directory."
                
                # Setup paths
                BIN_DIR="/usr/local/bin"
                CONF_DIR="/etc/mailuminati-guardian"
                CONF_FILE="${CONF_DIR}/guardian.conf"

                # Move binary to /usr/local/bin
                sudo mv mailuminati-guardian "${BIN_DIR}/mailuminati-guardian"
                log_success "Binary moved to ${BIN_DIR}/mailuminati-guardian."

                # Create config directory and file
                sudo mkdir -p "$CONF_DIR"
                if [ ! -f "$CONF_FILE" ]; then
                    log_info "Creating default configuration file at $CONF_FILE"
                    sudo tee "$CONF_FILE" > /dev/null <<EOF
# Mailuminati Guardian Configuration
# Created on $(date)

# Network
GUARDIAN_BIND_ADDR=127.0.0.1
PORT=12421

# Redis
REDIS_HOST=${REDIS_HOST:-localhost}
REDIS_PORT=${REDIS_PORT:-6379}

# Weights & Logic
# SPAM_WEIGHT=1
# HAM_WEIGHT=2
# LOCAL_RETENTION_DAYS=15

# Oracle
ORACLE_URL=https://oracle.mailuminati.com
EOF
                else
                    log_info "Configuration file already exists at $CONF_FILE, keeping it."
                fi

                # Create system user if not exists
                if ! id -u mailuminati &>/dev/null; then
                    sudo useradd --system --no-create-home --shell /usr/sbin/nologin mailuminati
                    log_success "System user 'mailuminati' created."
                else
                    log_info "System user 'mailuminati' already exists."
                fi
                
                # Set ownership of config (readable by mailuminati)
                sudo chown -R root:mailuminati "$CONF_DIR"
                sudo chmod 750 "$CONF_DIR"
                sudo chmod 640 "$CONF_FILE"

                # Create systemd service
                SERVICE_FILE="/etc/systemd/system/mailuminati-guardian.service"

                sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Mailuminati Guardian Service
After=network.target

[Service]
Type=simple
ExecStart=${BIN_DIR}/mailuminati-guardian -config ${CONF_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=5
User=mailuminati
# Environment variables can still override config file if needed, 
# but mostly we rely on the config file now.

[Install]
WantedBy=multi-user.target
EOF
                log_success "Systemd service file created at $SERVICE_FILE (running as 'mailuminati')."
                # Reload, enable and start the service
                sudo systemctl daemon-reload
                sudo systemctl enable mailuminati-guardian
                sudo systemctl restart mailuminati-guardian
                log_success "Mailuminati Guardian service started and enabled."
                log_success "The project is now listening on port 12421."
                started_ok=1
            else
                log_error "Build failed. Please check the Go output above."
            fi

            popd >/dev/null || true
            [ "$started_ok" = "1" ] && post_start_flow
        else
            log_error "No 'main.go' file found in the 'mi_guardian' directory. Please check your source tree."
        fi
    fi
}

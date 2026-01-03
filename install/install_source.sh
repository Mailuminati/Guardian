#!/bin/bash

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
                # Move binary to /opt/Mailuminati
                sudo mkdir -p /opt/Mailuminati
                sudo mv mailuminati-guardian /opt/Mailuminati/mailuminati-guardian
                log_success "Binary moved to /opt/Mailuminati/mailuminati-guardian."
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
ExecStart=/opt/Mailuminati/mailuminati-guardian
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

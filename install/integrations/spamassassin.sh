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

check_spamassassin_available() {
    if [ "${ENABLE_SPAMASSASSIN_INTEGRATION}" = "0" ]; then
        return 1
    fi
    command_exists spamassassin
}

get_spamassassin_name() {
    echo "SpamAssassin"
}

configure_spamassassin_integration() {
    detect_spamassassin_paths

    if [ -z "$SA_CONF_DIR" ] || [ -z "$SA_PLUGIN_DIR" ]; then
        log_error "Could not detect SpamAssassin configuration or plugin directories."
        return 1
    fi

    log_info "Installing Mailuminati SpamAssassin plugin..."
    
    # Safe path resolution
    local SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    local PROJECT_ROOT="$( cd "$SCRIPT_DIR/../../" && pwd )"

    # Copy Plugin
    if cp "$PROJECT_ROOT/Spamassassin/Mailuminati.pm" "$SA_PLUGIN_DIR/"; then
        log_success "Copied Mailuminati.pm to $SA_PLUGIN_DIR"
    else
        log_error "Failed to copy Mailuminati.pm from $PROJECT_ROOT/Spamassassin/"
        return 1
    fi

    # Copy Config
    if cp "$PROJECT_ROOT/Spamassassin/mailuminati.cf" "$SA_CONF_DIR/"; then
        log_success "Copied mailuminati.cf to $SA_CONF_DIR"
    else
        log_error "Failed to copy mailuminati.cf from $PROJECT_ROOT/Spamassassin/"
        return 1
    fi

    # Check for dependencies
    if ! perl -MJSON -e 1 2>/dev/null; then
        log_warn "Perl module JSON is missing. Please install it (e.g., apt install libjson-perl or cpan JSON)."
    fi
    if ! perl -MLWP::UserAgent -e 1 2>/dev/null; then
        log_warn "Perl module LWP::UserAgent is missing. Please install it (e.g., apt install libwww-perl)."
    fi

    # Restart SpamAssassin
    log_info "Restarting SpamAssassin..."
    local SERVICES="spamassassin spamd"
    local RESTARTED=0
    
    if command_exists systemctl; then
        for svc in $SERVICES; do
            # Check if service exists (enabled or not)
            if systemctl list-unit-files "$svc.service" >/dev/null 2>&1 || systemctl list-units --all "$svc.service" | grep -q "$svc.service"; then
                if sudo systemctl restart "$svc.service"; then
                    log_success "Restarted $svc.service"
                    RESTARTED=1
                    break
                fi
            fi
        done
    elif command_exists service; then
        for svc in $SERVICES; do
             if service "$svc" status >/dev/null 2>&1 || service --status-all 2>&1 | grep -q "$svc"; then
                if sudo service "$svc" restart; then
                     log_success "Restarted $svc"
                     RESTARTED=1
                     break
                fi
             fi
        done
    fi
    
    if [ "$RESTARTED" -eq "0" ]; then
        log_warn "Could not restart SpamAssassin automatically. Please restart 'spamassassin' or 'spamd' manually."
    fi

    echo -e "\n--------------------------------------------------"
    log_info "SpamAssassin integration installed."
    log_info "Please verify that SpamAssassin is running and the Mailuminati plugin is loaded."
    echo -e "--------------------------------------------------\n"
}


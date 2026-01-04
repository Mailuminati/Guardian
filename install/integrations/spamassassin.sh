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
    
    # Copy Plugin
    cp "$(dirname "$0")/../../Spamassassin/Mailuminati.pm" "$SA_PLUGIN_DIR/"
    log_success "Copied Mailuminati.pm to $SA_PLUGIN_DIR"

    # Copy Config
    cp "$(dirname "$0")/../../Spamassassin/mailuminati.cf" "$SA_CONF_DIR/"
    log_success "Copied mailuminati.cf to $SA_CONF_DIR"

    # Check for dependencies
    if ! perl -MJSON -e 1 2>/dev/null; then
        log_warn "Perl module JSON is missing. Please install it (e.g., apt install libjson-perl or cpan JSON)."
    fi
    if ! perl -MLWP::UserAgent -e 1 2>/dev/null; then
        log_warn "Perl module LWP::UserAgent is missing. Please install it (e.g., apt install libwww-perl)."
    fi

    echo -e "\n--------------------------------------------------"
    log_info "SpamAssassin integration installed."
    log_info "Please restart SpamAssassin to apply changes:"
    log_info "  systemctl restart spamassassin"
    echo -e "--------------------------------------------------\n"
}


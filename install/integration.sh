#!/bin/bash

detect_rspamd_paths() {
    RSPAMD_CONF_ROOT=""
    RSPAMD_LOCAL_D=""
    RSPAMD_OVERRIDE_D=""
    RSPAMD_LUA_DIR=""

    # Common distro paths
    RSPAMD_CONF_ROOT="$(first_existing_dir \
        "/etc/rspamd" \
        "/usr/local/etc/rspamd" \
        "/opt/rspamd/etc/rspamd" \
    )" || true

    if [ -n "$RSPAMD_CONF_ROOT" ]; then
        RSPAMD_LOCAL_D="$(first_existing_dir "${RSPAMD_CONF_ROOT}/local.d" "${RSPAMD_CONF_ROOT}/override.d")" || true
        RSPAMD_OVERRIDE_D="$(first_existing_dir "${RSPAMD_CONF_ROOT}/override.d")" || true
        RSPAMD_LUA_DIR="$(first_existing_dir "${RSPAMD_CONF_ROOT}/lua")" || true
    fi

    # Common share paths for Lua (rules/plugins)
    if [ -z "$RSPAMD_LUA_DIR" ]; then
        RSPAMD_LUA_DIR="$(first_existing_dir \
            "/usr/share/rspamd/lua" \
            "/usr/local/share/rspamd/lua" \
            "/opt/rspamd/share/rspamd/lua" \
        )" || true
    fi

    # Final fallback
    [ -z "$RSPAMD_LOCAL_D" ] && RSPAMD_LOCAL_D="$RSPAMD_CONF_ROOT/local.d"
    [ -z "$RSPAMD_OVERRIDE_D" ] && RSPAMD_OVERRIDE_D="$RSPAMD_CONF_ROOT/override.d"
}

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

configure_rspamd_integration() {
    detect_rspamd_paths

    local sudo_cmd=""
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        sudo_cmd="sudo"
    fi

    local suggested_conf_root="${RSPAMD_CONF_ROOT:-/etc/rspamd}"
    local rspamd_conf_root=""

    echo -e "\n--------------------------------------------------"
    log_info "Rspamd integration (interactive)"
    log_info "Detected config root (best-effort): ${suggested_conf_root}"
    echo "--------------------------------------------------"

    while true; do
        read -r -p "Rspamd configuration root [${suggested_conf_root}]: " rspamd_conf_root
        rspamd_conf_root="${rspamd_conf_root:-$suggested_conf_root}"

        echo
        log_info "Selected: ${rspamd_conf_root}"
        if confirm_yes_no "Use this path" "y"; then
            break
        fi
        suggested_conf_root="$rspamd_conf_root"
    done

    if [ ! -d "$rspamd_conf_root" ]; then
        log_warning "Rspamd config directory does not exist: $rspamd_conf_root"
        if ! confirm_yes_no "Create it" "n"; then
            log_error "Cannot proceed without a valid Rspamd config directory."
            return 1
        fi
        if ! $sudo_cmd mkdir -p "$rspamd_conf_root"; then
            log_error "Failed to create: $rspamd_conf_root"
            return 1
        fi
        log_success "Created: $rspamd_conf_root"
    fi

    # Ensure local lua directory exists (even if not provided by default)
    local rspamd_local_lua_dir="${rspamd_conf_root}/lua"
    if ! $sudo_cmd mkdir -p "$rspamd_local_lua_dir"; then
        log_error "Failed to create: $rspamd_local_lua_dir"
        return 1
    fi

    # Ensure local.d exists for .conf drop-ins
    local rspamd_local_d_dir="${rspamd_conf_root}/local.d"
    if ! $sudo_cmd mkdir -p "$rspamd_local_d_dir"; then
        log_error "Failed to create: $rspamd_local_d_dir"
        return 1
    fi

    local rspamd_local_lua_file="${rspamd_conf_root}/rspamd.local.lua"
    if [ ! -f "$rspamd_local_lua_file" ]; then
        log_info "Creating ${rspamd_local_lua_file}"
        if ! cat <<EOF | $sudo_cmd tee "$rspamd_local_lua_file" >/dev/null
-- Local overrides for Rspamd (Mailuminati Guardian)
EOF
        then
            log_error "Failed to create: $rspamd_local_lua_file"
            return 1
        fi
        log_success "Created: $rspamd_local_lua_file"
    fi

    # Ensure Mailuminati module is loaded
    local dofile_line="dofile(\"${rspamd_local_lua_dir}/mailuminati.lua\")"
    if grep -Eq 'dofile\([^\)]*mailuminati\.lua' "$rspamd_local_lua_file" 2>/dev/null; then
        log_success "Mailuminati dofile already present in rspamd.local.lua"
    else
        log_info "Adding Mailuminati dofile to rspamd.local.lua"
        if ! printf "\n%s\n" "$dofile_line" | $sudo_cmd tee -a "$rspamd_local_lua_file" >/dev/null; then
            log_error "Failed to update: $rspamd_local_lua_file"
            return 1
        fi
        log_success "Updated: $rspamd_local_lua_file"
    fi

    # Copy (overwrite) the Mailuminati lua module shipped with Guardian
    # Note: INSTALLER_DIR must be available from the main script
    local lua_src="${INSTALLER_DIR}/Rspamd/mailuminati.lua"
    local lua_dst="${rspamd_local_lua_dir}/mailuminati.lua"

    if [ ! -f "$lua_src" ]; then
        log_error "Cannot find source lua module: $lua_src"
        log_info "Expected it inside the Guardian install directory under: Rspamd/mailuminati.lua"
        return 1
    fi

    if command_exists install; then
        if ! $sudo_cmd install -m 0644 "$lua_src" "$lua_dst"; then
            log_error "Failed to install: $lua_dst"
            return 1
        fi
    else
        if ! $sudo_cmd cp -f "$lua_src" "$lua_dst"; then
            log_error "Failed to copy: $lua_dst"
            return 1
        fi
    fi
    log_success "Installed: $lua_dst"

    # Validate Rspamd configuration
    log_info "Validating Rspamd configuration..."
    local config_ok=0
    if command_exists rspamadm; then
        if rspamadm configtest -c "$rspamd_conf_root" >/dev/null 2>&1; then
            config_ok=1
        elif rspamadm configtest >/dev/null 2>&1; then
            config_ok=1
        fi
    elif command_exists rspamd; then
        # Best-effort fallback
        if rspamd -t -c "$rspamd_conf_root" >/dev/null 2>&1; then
            config_ok=1
        elif rspamd -t >/dev/null 2>&1; then
            config_ok=1
        fi
    fi

    if [ "$config_ok" != "1" ]; then
        log_error "Rspamd config test failed (or could not be run). Not reloading service."
        log_info "Try manually: sudo rspamadm configtest -c ${rspamd_conf_root}"
        return 1
    fi
    log_success "Rspamd configuration looks valid."

    # Reload Rspamd
    log_info "Reloading Rspamd service..."
    if command_exists systemctl; then
        if $sudo_cmd systemctl reload rspamd >/dev/null 2>&1; then
            log_success "Rspamd reloaded (systemctl reload)."
            return 0
        fi
        log_warning "Reload failed; trying restart (systemctl restart)."
        if $sudo_cmd systemctl restart rspamd >/dev/null 2>&1; then
            log_success "Rspamd restarted (systemctl restart)."
            return 0
        fi
    elif command_exists service; then
        if $sudo_cmd service rspamd reload >/dev/null 2>&1; then
            log_success "Rspamd reloaded (service reload)."
            return 0
        fi
        log_warning "Reload failed; trying restart (service restart)."
        if $sudo_cmd service rspamd restart >/dev/null 2>&1; then
            log_success "Rspamd restarted (service restart)."
            return 0
        fi
    fi

    log_warning "Could not automatically reload Rspamd. Please reload it manually."
    log_info "Examples: sudo systemctl reload rspamd  OR  sudo systemctl restart rspamd"
    return 2
}

print_spamassassin_integration_instructions() {
    detect_spamassassin_paths

    echo -e "\n--------------------------------------------------"
    log_info "SpamAssassin integration (manual steps):"
    log_info "Detected paths (best-effort):"
    echo " - SA_CONF_DIR:    ${SA_CONF_DIR:-<unknown>}"
    echo " - SA_PLUGIN_DIR:  ${SA_PLUGIN_DIR:-<unknown>}"
    echo
    echo "1) Prefer placing your Mailuminati .cf rules in: ${SA_CONF_DIR:-/etc/mail/spamassassin}"
    echo "2) If you ship a custom Perl plugin, place it in: ${SA_PLUGIN_DIR:-<perl site/lib>/Mail/SpamAssassin/Plugin}"
    echo "3) Add a custom check (plugin or wrapper) that submits the message (MIME) to: http://127.0.0.1:1133/analyze"
    echo "4) If response action==spam: add a rule hit and score accordingly."
    echo "5) Optionally forward user feedback to: http://127.0.0.1:1133/report"
    echo "6) Restart spamd/spamassassin service."
    log_info "Note: This installer currently prints guidance only (no files are written)."
    echo -e "--------------------------------------------------\n"
}

offer_filter_integration() {
    if [ "${OFFER_FILTER_INTEGRATION}" != "1" ]; then
        log_info "Skipping mail filter integration (disabled by option/env)."
        return 0
    fi

    local has_rspamd=0
    local has_sa=0
    if [ "${ENABLE_RSPAMD_INTEGRATION}" = "1" ] && command_exists rspamd; then
        has_rspamd=1
    fi
    if [ "${ENABLE_SPAMASSASSIN_INTEGRATION}" = "1" ] && command_exists spamassassin; then
        has_sa=1
    fi

    if [ "$has_rspamd" != "1" ] && [ "$has_sa" != "1" ]; then
        log_info "No supported mail filter detected (rspamd/spamassassin). Skipping integration guidance."
        return 0
    fi

    echo -e "\n--------------------------------------------------"
    log_info "Optional: install mail filter integration now?"
    echo "--------------------------------------------------"

    local default_choice="3"
    if [ "$has_rspamd" = "1" ]; then
        echo "1) Rspamd integration (recommended)"
        default_choice="1"
    else
        echo "1) Rspamd integration (unavailable)"
    fi

    if [ "$has_sa" = "1" ]; then
        echo "2) SpamAssassin integration"
        [ "$default_choice" = "3" ] && default_choice="2"
    else
        echo "2) SpamAssassin integration (unavailable)"
    fi

    echo "3) Skip"

    while true; do
        read -r -p "Enter your choice [${default_choice}]: " choice
        choice=${choice:-$default_choice}
        case "$choice" in
            1)
                [ "$has_rspamd" = "1" ] || { log_error "Rspamd is not available on this system."; continue; }
                configure_rspamd_integration
                break
                ;;
            2)
                [ "$has_sa" = "1" ] || { log_error "SpamAssassin is not available on this system."; continue; }
                print_spamassassin_integration_instructions
                break
                ;;
            3)
                log_info "Skipping integration."
                break
                ;;
            *)
                log_error "Invalid option: $choice"
                ;;
        esac
    done
}

post_start_flow() {
    wait_for_status_ready "http://localhost:1133/status" 30 || true
    offer_filter_integration
}

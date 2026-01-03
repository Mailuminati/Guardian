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

detect_dovecot_paths() {
    DOVECOT_CONF_DIR=""
    DOVECOT_SIEVE_CONF=""

    DOVECOT_CONF_DIR="$(first_existing_dir \
        "/etc/dovecot" \
        "/usr/local/etc/dovecot" \
        "/opt/dovecot/etc/dovecot" \
    )" || true

    if [ -n "$DOVECOT_CONF_DIR" ]; then
        if [ -f "${DOVECOT_CONF_DIR}/conf.d/90-sieve.conf" ]; then
            DOVECOT_SIEVE_CONF="${DOVECOT_CONF_DIR}/conf.d/90-sieve.conf"
        elif [ -f "${DOVECOT_CONF_DIR}/90-sieve.conf" ]; then
             DOVECOT_SIEVE_CONF="${DOVECOT_CONF_DIR}/90-sieve.conf"
        fi
    fi
}

configure_dovecot_integration() {
    detect_dovecot_paths
    
    local sudo_cmd=""
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        sudo_cmd="sudo"
    fi

    echo -e "\n--------------------------------------------------"
    log_info "Dovecot integration (interactive)"
    log_info "Detected config dir: ${DOVECOT_CONF_DIR:-<unknown>}"
    log_info "Detected sieve conf: ${DOVECOT_SIEVE_CONF:-<not found>}"
    echo "--------------------------------------------------"

    if [ -z "$DOVECOT_SIEVE_CONF" ]; then
        log_warning "Could not find 90-sieve.conf."
        
        local target_dir=""
        if [ -n "$DOVECOT_CONF_DIR" ]; then
            if [ -d "${DOVECOT_CONF_DIR}/conf.d" ]; then
                target_dir="${DOVECOT_CONF_DIR}/conf.d"
            else
                target_dir="${DOVECOT_CONF_DIR}"
            fi
        fi

        if [ -n "$target_dir" ]; then
             local proposed_conf="${target_dir}/90-sieve.conf"
             if confirm_yes_no "Create default ${proposed_conf}?" "y"; then
                 # Create the file with basic structure
                 {
                    echo "plugin {"
                    echo "  sieve_pipe_bin_dir = /usr/local/bin"
                    echo "}" 
                 } | $sudo_cmd tee "$proposed_conf" >/dev/null
                 
                 DOVECOT_SIEVE_CONF="$proposed_conf"
                 log_success "Created $DOVECOT_SIEVE_CONF"
             else
                 log_warning "Skipping automatic configuration."
                 return 1
             fi
        else
             log_warning "Skipping automatic configuration (Dovecot config dir not found)."
             return 1
        fi
    fi

    log_info "Checking $DOVECOT_SIEVE_CONF for required plugins..."
    
    if grep -q "sieve_plugins.*sieve_imapsieve" "$DOVECOT_SIEVE_CONF" && \
       grep -q "sieve_plugins.*sieve_extprograms" "$DOVECOT_SIEVE_CONF"; then
        log_success "sieve_imapsieve and sieve_extprograms seem to be already enabled."
        return 0
    fi

    echo
    log_info "We need to ensure 'sieve_imapsieve' and 'sieve_extprograms' are in 'sieve_plugins'."
    if ! confirm_yes_no "Attempt to patch $DOVECOT_SIEVE_CONF automatically?" "y"; then
        log_info "Skipping. Please manually ensure: plugin { sieve_plugins = sieve_imapsieve sieve_extprograms }"
        return 0
    fi

    $sudo_cmd cp "$DOVECOT_SIEVE_CONF" "${DOVECOT_SIEVE_CONF}.bak.$(date +%s)"
    log_info "Backed up to ${DOVECOT_SIEVE_CONF}.bak.$(date +%s)"

    if grep -q "^[[:space:]]*sieve_plugins[[:space:]]*=" "$DOVECOT_SIEVE_CONF"; then
        log_info "sieve_plugins directive found. Appending missing plugins..."
        if ! grep -q "sieve_imapsieve" "$DOVECOT_SIEVE_CONF"; then
             $sudo_cmd sed -i 's/^\([[:space:]]*sieve_plugins[[:space:]]*=[^#]*\)/\1 sieve_imapsieve/' "$DOVECOT_SIEVE_CONF"
             log_success "Added sieve_imapsieve"
        fi
        if ! grep -q "sieve_extprograms" "$DOVECOT_SIEVE_CONF"; then
             $sudo_cmd sed -i 's/^\([[:space:]]*sieve_plugins[[:space:]]*=[^#]*\)/\1 sieve_extprograms/' "$DOVECOT_SIEVE_CONF"
             log_success "Added sieve_extprograms"
        fi
    else
        if grep -q "^plugin[[:space:]]*{" "$DOVECOT_SIEVE_CONF"; then
             log_info "Adding sieve_plugins directive to existing plugin block..."
             $sudo_cmd sed -i '/^plugin[[:space:]]*{/a \  sieve_plugins = sieve_imapsieve sieve_extprograms' "$DOVECOT_SIEVE_CONF"
             log_success "Added sieve_plugins directive."
        else
             log_info "No plugin block found. Appending one..."
             echo -e "\nplugin {\n  sieve_plugins = sieve_imapsieve sieve_extprograms\n}\n" | $sudo_cmd tee -a "$DOVECOT_SIEVE_CONF" >/dev/null
             log_success "Appended plugin block."
        fi
    fi
    
    log_info "Reloading Dovecot..."
    if command_exists systemctl; then
        $sudo_cmd systemctl reload dovecot
    elif command_exists service; then
        $sudo_cmd service dovecot reload
    fi
}

offer_filter_integration() {
    if [ "${OFFER_FILTER_INTEGRATION}" != "1" ]; then
        log_info "Skipping mail filter integration (disabled by option/env)."
        return 0
    fi

    local has_rspamd=0
    local has_sa=0
    local has_dovecot=0

    if [ "${ENABLE_RSPAMD_INTEGRATION}" = "1" ] && command_exists rspamd; then
        has_rspamd=1
    fi
    if [ "${ENABLE_SPAMASSASSIN_INTEGRATION}" = "1" ] && command_exists spamassassin; then
        has_sa=1
    fi
    if command_exists dovecot; then
        has_dovecot=1
    fi

    if [ "$has_rspamd" != "1" ] && [ "$has_sa" != "1" ] && [ "$has_dovecot" != "1" ]; then
        log_info "No supported mail filter detected (rspamd/spamassassin/dovecot). Skipping integration guidance."
        return 0
    fi

    # --- Step 1: Spam Filter Integration ---
    if [ "$has_rspamd" = "1" ] || [ "$has_sa" = "1" ]; then
        echo -e "\n--------------------------------------------------"
        log_info "Step 1: Mail Filter Integration"
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

        echo "3) Skip filter integration"

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
                    log_info "Skipping filter integration."
                    break
                    ;;
                *)
                    log_error "Invalid option: $choice"
                    ;;
            esac
        done
    fi

    # --- Step 2: Dovecot Integration ---
    if [ "$has_dovecot" = "1" ]; then
        echo -e "\n--------------------------------------------------"
        log_info "Step 2: Dovecot Integration (Sieve)"
        echo "--------------------------------------------------"
        
        if confirm_yes_no "Configure Dovecot Sieve plugins (sieve_imapsieve, sieve_extprograms)?" "y"; then
             configure_dovecot_integration
        else
             log_info "Skipping Dovecot integration."
        fi
    fi
}

post_start_flow() {
    wait_for_status_ready "http://localhost:1133/status" 30 || true
    offer_filter_integration
}

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

    # --- Configure IMAPSieve Rules ---
    log_info "Configuring IMAPSieve rules for Spam/Ham reporting..."

    # 1. Create Sieve Scripts Directory
    local sieve_global_dir="/etc/dovecot/sieve"
    if [ ! -d "$sieve_global_dir" ]; then
        $sudo_cmd mkdir -p "$sieve_global_dir"
        log_success "Created directory $sieve_global_dir"
    fi

    # 2. Create Sieve Scripts
    local report_spam_sieve="${sieve_global_dir}/report-spam.sieve"
    local report_ham_sieve="${sieve_global_dir}/report-ham.sieve"

    # report-spam.sieve
    echo 'require ["vnd.dovecot.pipe", "copy", "imapsieve"];
pipe :copy "guardian-report.sh" ["spam"];' | $sudo_cmd tee "$report_spam_sieve" >/dev/null
    log_success "Created $report_spam_sieve"

    # report-ham.sieve
    echo 'require ["vnd.dovecot.pipe", "copy", "imapsieve"];
pipe :copy "guardian-report.sh" ["ham"];' | $sudo_cmd tee "$report_ham_sieve" >/dev/null
    log_success "Created $report_ham_sieve"

    # 3. Compile Sieve Scripts
    if command_exists sievec; then
        $sudo_cmd sievec "$report_spam_sieve"
        $sudo_cmd sievec "$report_ham_sieve"
        log_success "Compiled sieve scripts."
    else
        log_warning "sievec command not found. You may need to compile the scripts manually."
    fi

    # 4. Set Permissions
    # Try to detect vmail user/group, fallback to dovecot or root
    local dovecot_user="vmail"
    if ! id -u vmail >/dev/null 2>&1; then
        if id -u dovecot >/dev/null 2>&1; then
            dovecot_user="dovecot"
        else
            dovecot_user="root"
        fi
    fi
    
    $sudo_cmd chown -R "$dovecot_user:$dovecot_user" "$sieve_global_dir"
    $sudo_cmd chmod 644 "${sieve_global_dir}"/*.sieve
    if ls "${sieve_global_dir}"/*.svbin >/dev/null 2>&1; then
        $sudo_cmd chmod 644 "${sieve_global_dir}"/*.svbin
    fi
    log_success "Set permissions for sieve scripts (User: $dovecot_user)."

    # 5. Install guardian-report.sh
    local source_script="${INSTALLER_DIR}/Dovecot/guardian-report.sh"
    local target_script="/usr/local/bin/guardian-report.sh"
    
    if [ -f "$source_script" ]; then
        $sudo_cmd cp "$source_script" "$target_script"
        $sudo_cmd chmod +x "$target_script"
        log_success "Installed $target_script"
    else
        log_warning "Could not find source script at $source_script. Skipping copy."
    fi

    # 6. Configure 90-sieve.conf with dynamic IDs
    log_info "Injecting IMAPSieve configuration into $DOVECOT_SIEVE_CONF..."

    # Find the highest existing mailbox ID
    local max_id=0
    if [ -f "$DOVECOT_SIEVE_CONF" ]; then
        # Extract all numbers X from imapsieve_mailboxX_name, sort them, take the last one
        local found_id
        found_id=$(grep -o 'imapsieve_mailbox[0-9]*_name' "$DOVECOT_SIEVE_CONF" | grep -o '[0-9]*' | sort -rn | head -1)
        if [ -n "$found_id" ]; then
            max_id=$found_id
        fi
    fi
    
    log_info "Starting with imapsieve_mailbox ID: $((max_id + 1))"

    # Helper to append config block
    append_sieve_config() {
        local name="$1"
        local from="$2"
        local cause="$3"
        local script="$4"
        
        max_id=$((max_id + 1))
        
        local config_block=""
        config_block+="  imapsieve_mailbox${max_id}_name = \"$name\""
        if [ -n "$from" ]; then
            config_block+=$'\n'"  imapsieve_mailbox${max_id}_from = \"$from\""
        fi
        config_block+=$'\n'"  imapsieve_mailbox${max_id}_causes = $cause"
        config_block+=$'\n'"  imapsieve_mailbox${max_id}_before = file:$script"
        
        # Insert into the plugin block
        # We use sed to insert before the closing brace of the plugin block
        # This assumes the file ends with a closing brace '}' for the plugin block or has one.
        # A safer approach for simple appending inside the last plugin { ... } block:
        
        # We will construct a temporary file with the block to append
        echo "$config_block" | $sudo_cmd tee -a "$DOVECOT_SIEVE_CONF.append" >/dev/null
    }

    # Clear temp append file
    $sudo_cmd rm -f "$DOVECOT_SIEVE_CONF.append"

    # SPAM Reporting (Move TO Spam/Junk)
    append_sieve_config "Junk" "" "COPY" "$report_spam_sieve"
    append_sieve_config "Spam" "" "COPY" "$report_spam_sieve"
    append_sieve_config "INBOX.Spam" "" "COPY" "$report_spam_sieve"
    append_sieve_config "INBOX.Junk" "" "COPY" "$report_spam_sieve"

    # HAM Reporting (Move FROM Spam/Junk)
    append_sieve_config "*" "Junk" "COPY" "$report_ham_sieve"
    append_sieve_config "*" "Spam" "COPY" "$report_ham_sieve"
    append_sieve_config "*" "INBOX.Spam" "COPY" "$report_ham_sieve"
    append_sieve_config "*" "INBOX.Junk" "COPY" "$report_ham_sieve"

    # Now inject the content of .append file into the configuration file
    # We look for the last occurrence of "}" and insert before it, 
    # OR if we just created the file, we can just append inside the plugin block.
    
    # Simple strategy: Read the append file and use sed to insert it before the last line that contains '}'
    # This is a bit fragile but works for standard dovecot configs.
    
    if [ -f "$DOVECOT_SIEVE_CONF.append" ]; then
        local content_to_inject
        content_to_inject=$(cat "$DOVECOT_SIEVE_CONF.append")
        
        # Escape newlines for sed
        content_to_inject="${content_to_inject//$'\n'/\\n}"
        
        # Insert before the last closing brace
        # If the file has multiple plugin blocks, this might be tricky. 
        # Assuming standard 90-sieve.conf structure where the whole file is often inside plugin { } or has one main plugin { } block.
        
        # Let's try to find "plugin {" and append after it if we can't reliably find the end.
        # Actually, appending to the end of the file (before the last }) is safer if we assume the file ends with }.
        
        # Check if file ends with }
        if tail -n1 "$DOVECOT_SIEVE_CONF" | grep -q "}"; then
             # Remove the last line (}), append our content, then add } back
             $sudo_cmd sed -i '$d' "$DOVECOT_SIEVE_CONF"
             cat "$DOVECOT_SIEVE_CONF.append" | $sudo_cmd tee -a "$DOVECOT_SIEVE_CONF" >/dev/null
             echo "}" | $sudo_cmd tee -a "$DOVECOT_SIEVE_CONF" >/dev/null
             log_success "Injected IMAPSieve rules into $DOVECOT_SIEVE_CONF"
        else
             # Fallback: just append and hope it's inside a block or valid
             cat "$DOVECOT_SIEVE_CONF.append" | $sudo_cmd tee -a "$DOVECOT_SIEVE_CONF" >/dev/null
             log_warning "Appended rules to end of file (could not find closing brace). Please verify syntax."
        fi
        
        $sudo_cmd rm -f "$DOVECOT_SIEVE_CONF.append"
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

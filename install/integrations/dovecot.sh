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

check_dovecot_available() {
    command_exists dovecot
}

get_dovecot_name() {
    echo "Dovecot (Sieve)"
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
    else
        echo
        log_info "We need to ensure 'sieve_imapsieve' and 'sieve_extprograms' are in 'sieve_plugins'."
        if ! confirm_yes_no "Attempt to patch $DOVECOT_SIEVE_CONF automatically?" "y"; then
            log_info "Skipping. Please manually ensure: plugin { sieve_plugins = sieve_imapsieve sieve_extprograms }"
        else
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
        fi
    fi

    # --- Ensure sieve_extensions has +copy +imap4flags +vnd.dovecot.pipe ---
    log_info "Checking sieve_extensions for required extensions..."
    local required_exts=("+copy" "+imap4flags" "+vnd.dovecot.pipe")
    local exts_changed=0

    if grep -q "^[[:space:]]*sieve_extensions[[:space:]]*=" "$DOVECOT_SIEVE_CONF"; then
        for ext in "${required_exts[@]}"; do
            # Escape + for grep (just to be safe, though + is literal in BRE)
            local escaped_ext="${ext//+/\\+}"
            if ! grep -q "sieve_extensions.*$escaped_ext" "$DOVECOT_SIEVE_CONF"; then
                 log_info "Adding missing extension: $ext"
                 $sudo_cmd sed -i "s/^\([[:space:]]*sieve_extensions[[:space:]]*=[^#]*\)/\1 $ext/" "$DOVECOT_SIEVE_CONF"
                 exts_changed=1
            fi
        done
    else
        log_info "sieve_extensions directive not found. Adding it..."
        if grep -q "^[[:space:]]*sieve_plugins[[:space:]]*=" "$DOVECOT_SIEVE_CONF"; then
             $sudo_cmd sed -i "/^[[:space:]]*sieve_plugins[[:space:]]*=/a \  sieve_extensions = +copy +imap4flags +vnd.dovecot.pipe" "$DOVECOT_SIEVE_CONF"
        elif grep -q "^plugin[[:space:]]*{" "$DOVECOT_SIEVE_CONF"; then
             $sudo_cmd sed -i '/^plugin[[:space:]]*{/a \  sieve_extensions = +copy +imap4flags +vnd.dovecot.pipe' "$DOVECOT_SIEVE_CONF"
        else
             echo -e "\nplugin {\n  sieve_extensions = +copy +imap4flags +vnd.dovecot.pipe\n}\n" | $sudo_cmd tee -a "$DOVECOT_SIEVE_CONF" >/dev/null
        fi
        exts_changed=1
    fi
    
    if [ "$exts_changed" = "1" ]; then
        log_success "Updated sieve_extensions."
    else
        log_success "sieve_extensions already configured correctly."
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
        log_error "sievec command not found. Cannot compile sieve scripts."
        log_info "Please install dovecot-sieve / dovecot-pigeonhole package."
        return 1
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
        
        # Check if rule already exists
        # We look for a block that has the same name, from (if set), cause and script
        # This is a basic check to avoid duplicates
        
        local check_pattern="imapsieve_mailbox[0-9]*_name = \"$name\""
        if grep -q "$check_pattern" "$DOVECOT_SIEVE_CONF"; then
            # If name matches, check if other params match in the file (rough check)
            # To be safe, we can just skip if we see the name and the script associated nearby
            # But since IDs are unique, it's hard to grep multiline perfectly in shell without complex logic.
            # Let's assume if we find the name AND the script in the file, it's likely already there.
            if grep -q "file:$script" "$DOVECOT_SIEVE_CONF"; then
                 log_info "Rule for mailbox '$name' with script '$script' seems to exist. Skipping."
                 return
            fi
        fi

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

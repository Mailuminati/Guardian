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

check_rspamd_available() {
    if [ "${ENABLE_RSPAMD_INTEGRATION}" = "0" ]; then
        return 1
    fi
    command_exists rspamd
}

get_rspamd_name() {
    echo "Rspamd"
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

    # Copy (overwrite) the Mailuminati config file
    local conf_src="${INSTALLER_DIR}/Rspamd/mailuminati.conf"
    local conf_dst="${rspamd_local_d_dir}/mailuminati.conf"

    if [ -f "$conf_src" ]; then
        if command_exists install; then
            if ! $sudo_cmd install -m 0644 "$conf_src" "$conf_dst"; then
                log_error "Failed to install: $conf_dst"
                return 1
            fi
        else
            if ! $sudo_cmd cp -f "$conf_src" "$conf_dst"; then
                log_error "Failed to copy: $conf_dst"
                return 1
            fi
        fi
        log_success "Installed: $conf_dst"
    else
        log_warning "Cannot find source config file: $conf_src"
    fi


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

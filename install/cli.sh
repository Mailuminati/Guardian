#!/bin/bash

# --- CLI options / feature toggles ---
# Defaults keep existing behavior.
ENABLE_RSPAMD_INTEGRATION=1
ENABLE_SPAMASSASSIN_INTEGRATION=1
ENABLE_MTA_FILTER_CHECK=1
OFFER_FILTER_INTEGRATION=1

show_help() {
    cat <<'EOF'
Mailuminati Guardian Installer

Usage:
  ./install.sh [options]

Options:
  --no-rspamd              Disable Rspamd integration (even if installed)
  --no-spamassassin        Disable SpamAssassin integration (even if installed)
  --no-filter-check        Do not warn if no mail filter is installed
  --no-filter-integration  Do not offer integration steps after startup
  -h, --help               Show this help

Environment variables (override defaults):
  ENABLE_RSPAMD_INTEGRATION=0|1
  ENABLE_SPAMASSASSIN_INTEGRATION=0|1
  ENABLE_MTA_FILTER_CHECK=0|1
  OFFER_FILTER_INTEGRATION=0|1
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --no-rspamd)
                ENABLE_RSPAMD_INTEGRATION=0
                ;;
            --no-spamassassin)
                ENABLE_SPAMASSASSIN_INTEGRATION=0
                ;;
            --no-filter-check)
                ENABLE_MTA_FILTER_CHECK=0
                ;;
            --no-filter-integration)
                OFFER_FILTER_INTEGRATION=0
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                log_info "Run: ./install.sh --help"
                exit 2
                ;;
        esac
        shift
    done
}

#!/bin/bash

# --- CLI options / feature toggles ---
# Defaults keep existing behavior.
ENABLE_RSPAMD_INTEGRATION=1
ENABLE_SPAMASSASSIN_INTEGRATION=1
ENABLE_MTA_FILTER_CHECK=1
OFFER_FILTER_INTEGRATION=1
REDIS_HOST=""
REDIS_PORT=""

show_help() {
    cat <<'EOF'
Mailuminati Guardian Installer

Usage:
  ./install.sh [options]

Options:
  --redis-host <host>      Specify Redis host (default: localhost for source, mi-redis for docker)
  --redis-port <port>      Specify Redis port (default: 6379)
  --no-rspamd              Disable Rspamd integration (even if installed)
  --no-spamassassin        Disable SpamAssassin integration (even if installed)
  --no-filter-check        Do not warn if no mail filter is installed
  --no-filter-integration  Do not offer integration steps after startup
  -h, --help               Show this help

Environment variables (override defaults):
  REDIS_HOST
  REDIS_PORT
  ENABLE_RSPAMD_INTEGRATION=0|1
  ENABLE_SPAMASSASSIN_INTEGRATION=0|1
  ENABLE_MTA_FILTER_CHECK=0|1
  OFFER_FILTER_INTEGRATION=0|1
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --redis-host)
                if [ -n "$2" ] && [ "${2:0:1}" != "-" ]; then
                    REDIS_HOST="$2"
                    shift
                else
                    log_error "Error: Argument for $1 is missing"
                    exit 2
                fi
                ;;
            --redis-port)
                if [ -n "$2" ] && [ "${2:0:1}" != "-" ]; then
                    REDIS_PORT="$2"
                    shift
                else
                    log_error "Error: Argument for $1 is missing"
                    exit 2
                fi
                ;;
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

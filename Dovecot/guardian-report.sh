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

# Configuration
API_URL="http://127.0.0.1:1133/report"

# Report type passed as argument by the Sieve script ("spam" or "ham")
REPORT_TYPE=$1

# Read the mail from standard input (stdin) provided by Dovecot
# Only keep the header to quickly extract the Message-ID
HEADERS=$(sed '/^$/q')

# Extract the Message-ID (case insensitive)
# The format expected by main.go is the raw header string
MSG_ID=$(echo "$HEADERS" | grep -i "^Message-ID:" | head -1 | sed 's/^Message-ID: *//i' | sed 's/ *$//')

# Security check
if [ -z "$MSG_ID" ] || [ -z "$REPORT_TYPE" ]; then
    # Log to system error if needed, or exit silently
    exit 0
fi

# Build the JSON
# main.go expects: {"message-id": "...", "report_type": "..."}
JSON_PAYLOAD=$(printf '{"message-id": "%s", "report_type": "%s"}' "$MSG_ID" "$REPORT_TYPE")

# Send to Guardian
# Use curl in silent mode (-s) to avoid polluting Dovecot logs
curl -s -X POST "$API_URL" \
     -H "Content-Type: application/json" \
     -d "$JSON_PAYLOAD" > /dev/null
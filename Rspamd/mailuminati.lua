-- Mailuminati Guardian 
-- Copyright (C) 2025 Simon Bressier
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, version 3.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <https://www.gnu.org/licenses/>.


-- Rspamd module for Mailuminati
-- Communicates with the Guardian, the Go sidecar on port 1133

local rspamd_logger = require "rspamd_logger"
local http = require "rspamd_http"
local ucl = require "ucl"

-- Log when the module is loaded
rspamd_logger.errx("Mailuminati: MODULE LOADED")

local options = {
    endpoint = "http://127.0.0.1:1133/analyze",
    report_endpoint = "http://127.0.0.1:1133/report",
    timeout = 5.0, -- Increased timeout for safety
    spam_score = 10.0,
    suspicious_score = 4.0
}

-- Read optional configuration
if rspamd_config then
    local opts = rspamd_config:get_all_opt("mailuminati")
    if opts then
        for k, v in pairs(opts) do
            options[k] = v
        end
    end
end

local function tlsh_check(task)
    local raw_msg = task:get_content()
    if not raw_msg or #raw_msg == 0 then
        rspamd_logger.errx(task, "Mailuminati: Empty message, aborting.")
        return
    end

    local function http_callback(err, code, body, headers)
        if err then
            rspamd_logger.errx(task, "Mailuminati HTTP ERROR: %s", err)
            return
        end

        if code == 200 and body then
            local parser = ucl.parser()
            local res, ucl_err = parser:parse_string(body)
            -- print body for debugging
            rspamd_logger.errx(task, "Mailuminati response body: %s", body)
            if res then
                local obj = parser:get_object()
                if obj.hashes and type(obj.hashes) == 'table' and #obj.hashes > 0 then
                    task:cache_set('mailuminati_hashes', obj.hashes)
                end
                if obj.action == "reject" then
                    task:insert_result("MAILUMINATI_SPAM", 1.0, obj.label or "match")
                elseif obj.proximity_match == true then
                    task:insert_result("MAILUMINATI_SUSPICIOUS", 1.0)
                end
            else
                rspamd_logger.errx(task, "Mailuminati: JSON parsing error: %s", ucl_err)
            end
        else
            rspamd_logger.errx(task, "Mailuminati: Sidecar returned non-200 code: %s", code)
        end
    end

    local request_initiated = http.request({
        task = task,
        url = options.endpoint,
        body = raw_msg,
        method = 'post',
        headers = {
            ['Content-Type'] = 'text/plain',
            ['User-Agent'] = 'Rspamd-Mailuminati-Lua'
        },
        callback = http_callback,
        timeout = options.timeout,
    })

    if not request_initiated then
        rspamd_logger.errx(task, "Mailuminati: CRITICAL - Failed to initialize http.request")
    end
end

-- Symbol registration
if rspamd_config then
    -- Use 'prefilter' to ensure it runs early
    rspamd_config:register_symbol({
        name = 'MAILUMINATI_CHECK',
        type = 'prefilter',
        callback = tlsh_check,
        priority = 10
    })

    -- Default symbol scores
    rspamd_config:set_metric_symbol({
        name = 'MAILUMINATI_SPAM',
        score = options.spam_score,
        description = 'Structural DNA match (Mailuminati)'
    })
    
    rspamd_config:set_metric_symbol({
        name = 'MAILUMINATI_SUSPICIOUS',
        score = options.suspicious_score,
        description = 'Strong structural proximity (Mailuminati)'
    })
end
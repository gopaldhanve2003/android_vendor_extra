#!/bin/bash
# telegram_notify.sh — optional. Sourced by vendorsetup.sh only if this
# file exists, so a checkout without it still builds fine, just silently.
# Requires: TG_TOKEN, TG_CID env vars (Telegram bot token + chat id).
#
# Reads TARGET_DEVICE / TARGET_BUILD_VARIANT — already exported by
# envsetup.sh's breakfast/lunch by the time `m bacon` runs, so no
# manual device/variant configuration needed here.

#######################################
# Telegram notification — direct Bot API, no external script
#######################################
notifyMsg() {
    local msg="$1"
    if [ -z "${msg_id}" ]; then
        local resp
        resp=$(curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
               -d chat_id="${TG_CID}" \
               -d parse_mode="HTML" \
               -d text="${msg}")
        msg_id=$(echo "$resp" | jq -r '.result.message_id')
    else
        curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/editMessageText" \
             -d chat_id="${TG_CID}" \
             -d parse_mode="HTML" \
             -d message_id="${msg_id}" \
             -d text="${msg}" > /dev/null 2>&1
    fi
}

#######################################
# Log upload to paste.rs
#######################################
upload_log() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "Error: File '$file' not found." >&2
        return 1
    fi
    local output_url
    output_url=$(curl --silent --data-binary @"$file" https://paste.rs)
    if [ -z "$output_url" ]; then
        if curl --silent --head https://paste.rs > /dev/null; then
            echo "Error: Upload failed despite paste.rs being up." >&2
        else
            echo "Error: Upload failed. paste.rs appears to be down." >&2
        fi
        return 1
    fi
    echo "$output_url"
}

#######################################
# Progress stream — reads m bacon's stdout live, line by line.
# `tr '\r' '\n'` normalizes Soong's status output first: it can pack
# many "\r"-separated updates before a real newline, which would
# otherwise make `read` return late and match a stale percentage.
# Throttled to once per 5s so Telegram isn't flooded.
#######################################
_progress_stream() {
    local label="$1"
    local last_prog="" last_ts=0 line prog now

    while IFS= read -r line; do
        printf '%s\n' "$line"
        if [[ "$line" =~ ([0-9]+%\ [0-9]+/[0-9]+) ]]; then
            prog="${BASH_REMATCH[1]}"
            now=$(date +%s)
            if [[ "$prog" != "$last_prog" && $(( now - last_ts )) -ge 5 ]]; then
                notifyMsg "<b>${label}</b>
Status: <b>${prog}</b>"
                last_prog="$prog"
                last_ts="$now"
            fi
        fi
    done
}

#######################################
# Final message — appears once build.sh sets $DOWNLOAD_URL after the
# build finishes. Armed only after a successful `m bacon`, checks
# before each subsequent command, fires once, then unhooks and cleans
# up after itself.
#######################################
notify_final() {
    local dl="$1"
    [ -z "${msg_id}" ] && return 0
    notifyMsg "<b>${PROJECT}-${RELEASE_VERSION} | ${TARGET_DEVICE}</b>
Status: <b>complete</b>
Download: ${dl}"
}

_download_watch() {
    if [ -n "${DOWNLOAD_URL:-}" ]; then
        notify_final "${DOWNLOAD_URL}"
        trap - DEBUG
        unset DOWNLOAD_URL
    fi
}

#######################################
# Wrap `m bacon` only — build.sh stays untouched.
# On failure: Android already writes out/error.log itself — just upload it.
#######################################
if declare -f m >/dev/null 2>&1 && ! declare -f _orig_m >/dev/null 2>&1; then
    eval "$(declare -f m | sed '1s/^m /_orig_m /')"

    m() {
        if [[ "$1" == "bacon" ]]; then
            local variant="Vanilla"
            [ -f "${ANDROID_BUILD_TOP}/vendor/gapps/arm64/arm64-vendor.mk" ] && variant="GMS"
            local label="${PROJECT}-${RELEASE_VERSION} | ${TARGET_DEVICE} (${variant}, ${TARGET_BUILD_VARIANT})"

            unset msg_id
            notifyMsg "<b>${label}</b>
Build started"

            _orig_m "$@" > >(tr '\r' '\n' | _progress_stream "${label}") 2>&1
            local ec=$?

            if [ "${ec}" -eq 0 ]; then
                unset DOWNLOAD_URL
                trap '_download_watch' DEBUG
            else
                local err_file="${ANDROID_BUILD_TOP}/out/error.log"
                local log_url
                if [ -f "${err_file}" ]; then
                    log_url=$(upload_log "${err_file}") || log_url="(upload failed)"
                else
                    log_url="(out/error.log not found)"
                fi

                notifyMsg "<b>${label}</b>
Status: <b>failed</b>. Log: ${log_url}"
            fi

            return "${ec}"
        else
            _orig_m "$@"
        fi
    }
fi

#!/bin/bash
# telegram_notify.sh — optional. Sourced by vendorsetup.sh only if this
# file exists, so a checkout without it still builds fine, just silently.
# Requires: TG_TOKEN, TG_CID env vars (Telegram bot token + chat id).
#
# Reads TARGET_PRODUCT / TARGET_BUILD_VARIANT — already exported by
# envsetup.sh's breakfast/lunch by the time `m bacon` runs, so no
# manual device/variant configuration needed here.

#######################################
# Telegram notification — direct Bot API, no external script
#######################################
notifyMsg() {
    local msg="$1" resp
    if [ -z "${msg_id}" ]; then
        resp=$(curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
               -d chat_id="${TG_CID}" -d parse_mode="HTML" -d text="${msg}")
        msg_id=$(echo "$resp" | jq -r '.result.message_id' 2>/dev/null)
        [ -z "${msg_id}" ] || [ "${msg_id}" == "null" ] && \
            echo "[TELEGRAM] send failed: $(echo "$resp" | jq -r '.description // "no response"' 2>/dev/null)" >&2
    else
        resp=$(curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/editMessageText" \
               -d chat_id="${TG_CID}" -d parse_mode="HTML" -d message_id="${msg_id}" -d text="${msg}")
        echo "$resp" | jq -e '.ok' >/dev/null 2>&1 || \
            echo "[TELEGRAM] edit failed: $(echo "$resp" | jq -r '.description // "no response"' 2>/dev/null)" >&2
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
# Header used by start/progress/failed messages. Reads BUILD_DEVICE /
# BUILD_VARIANT, set once per invocation in m() below — they outlive
# m()'s own scope because _download_watch (fired later via a DEBUG
# trap) needs them too, same lifetime DOWNLOAD_URL already relies on.
#######################################
_tg_header() {
    echo "<b>${PROJECT}-${RELEASE_VERSION}</b>
Build started for ${BUILD_DEVICE}
Flavour: ${BUILD_VARIANT} | Release: ${TARGET_BUILD_VARIANT}"
}

#######################################
# Progress stream — reads m bacon's stdout live, line by line.
# `tr '\r' '\n'` normalizes Soong's status output first: it can pack
# many "\r"-separated updates before a real newline, which would
# otherwise make `read` return late and match a stale percentage.
# Reformats "NN% X/Y" as "NN% (X/Y)". Throttled to once per 5s.
#######################################
_progress_stream() {
    local last_prog="" last_ts=0 line pct frac prog now

    while IFS= read -r line; do
        printf '%s\n' "$line"
        if [[ "$line" =~ ([0-9]+%)\ ([0-9]+/[0-9]+) ]]; then
            pct="${BASH_REMATCH[1]}"
            frac="${BASH_REMATCH[2]}"
            prog="${pct} (${frac})"
            now=$(date +%s)
            if [[ "$prog" != "$last_prog" && $(( now - last_ts )) -ge 5 ]]; then
                notifyMsg "$(_tg_header)
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
    notifyMsg "$(_tg_header)
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
# Wrap `m bacon`. NOTE: in this AOSP tree `m` is not a bash function —
# envsetup.sh explicitly `unset`s it and it resolves at call time as
# the standalone script build/soong/bin/m via PATH (added by
# breakfast/lunch). So we don't capture/rename an existing `m`
# function — there isn't one to capture. We just define our own `m`
# and shell out with `command m`, which bypasses shell functions and
# finds the real script. This works no matter when it's defined, since
# it only needs PATH set correctly at call time (after breakfast), not
# at source time — so no build.sh or vendorsetup.sh ordering changes
# are needed.
#######################################
m() {
    if [[ "$1" == "bacon" ]]; then
        BUILD_VARIANT="Vanilla"
        [ -f "${ANDROID_BUILD_TOP}/vendor/gapps/arm64/arm64-vendor.mk" ] && BUILD_VARIANT="GMS"
        BUILD_DEVICE="${TARGET_PRODUCT#*_}"

        unset msg_id
        notifyMsg "$(_tg_header)"

        command m "$@" > >(tr '\r' '\n' | _progress_stream) 2>&1
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

            notifyMsg "$(_tg_header)
Status: <b>failed</b>. Log: ${log_url}"
        fi

        return "${ec}"
    else
        command m "$@"
    fi
}

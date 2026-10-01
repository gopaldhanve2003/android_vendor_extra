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
# Log upload — sent as a Telegram document instead of to paste.rs.
# Kept as its own function since it hits a different API endpoint
# (sendDocument, multipart) than notifyMsg's sendMessage/editMessageText.
# Sent as a reply to $msg_id (the status message) so it's threaded
# under the build it belongs to, instead of landing as a bare
# unrelated message in the chat.
#######################################
upload_log() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "Error: File '$file' not found." >&2
        return 1
    fi
    local resp
    resp=$(curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendDocument" \
           -F chat_id="${TG_CID}" -F reply_to_message_id="${msg_id}" -F document=@"${file}")
    echo "$resp" | jq -e '.ok' >/dev/null 2>&1 || {
        echo "[TELEGRAM] upload failed: $(echo "$resp" | jq -r '.description // "no response"' 2>/dev/null)" >&2
        return 1
    }
}

#######################################
# Header used by start/progress/failed/final messages. BUILD_DEVICE /
# BUILD_VARIANT are set once per invocation in m() and outlive its
# scope, since _download_watch (fired later via a DEBUG trap) reads
# them too — same lifetime DOWNLOAD_URL already relies on.
#######################################
_tg_header() {
    echo "<b>${PROJECT}-${RELEASE_VERSION}</b>
Build started for ${BUILD_DEVICE}
Flavour: ${BUILD_VARIANT} | Release: ${TARGET_BUILD_VARIANT}"
}

#######################################
# Final message — appears once build.sh sets $DOWNLOAD_URL after the
# build finishes. Shows the last-seen percentage with "(completed)"
# instead of an X/Y fraction, matching the progress message's shape.
#######################################
notify_final() {
    local dl="$1"
    [ -z "${msg_id}" ] && return 0
    notifyMsg "$(_tg_header)
Status: <b>${LAST_PCT:-100%} (completed)</b>
Download: ${dl}"
}

_download_watch() {
    if [ -n "${DOWNLOAD_URL:-}" ]; then
        notify_final "${DOWNLOAD_URL}"
        trap - DEBUG
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
        [ "${WITH_GMS}" = "true" ] && BUILD_VARIANT="GMS"
        BUILD_DEVICE="${TARGET_PRODUCT#*_}"

        unset msg_id DOWNLOAD_URL LAST_PCT
        notifyMsg "$(_tg_header)"

        local log_file
        log_file=$(mktemp)

        ( set -o pipefail; command m "$@" 2>&1 | tee "${log_file}" ) &
        local build_pid=$!

        local prog last_prog="" last_pct="" last_ts=0 now ec
        while :; do
            prog=$(
                grep -Po '\d+% \d+/\d+' "${log_file}" |
                tail -n1 |
                sed -e 's/ / \(/' -e 's/$/)/'
            )

            if [[ -n "${prog}" && "${prog}" != "${last_prog}" ]]; then
                last_pct="${prog%% *}"
                now=$(date +%s)
                if (( now - last_ts >= 5 )); then
                    notifyMsg "$(_tg_header)
Status: <b>${prog}</b>"
                    last_ts="${now}"
                fi
                last_prog="${prog}"
            fi

            kill -0 "${build_pid}" 2>/dev/null || break

            sleep 1
        done

        wait "${build_pid}"
        ec=$?

        prog=$(
            grep -Po '\d+% \d+/\d+' "${log_file}" |
            tail -n1 |
            sed -e 's/ / \(/' -e 's/$/)/'
        )
        [ -n "${prog}" ] && last_pct="${prog%% *}"
        rm -f "${log_file}"

        LAST_PCT="${last_pct}"

        if [ "${ec}" -eq 0 ]; then
            trap '_download_watch' DEBUG
        else
            notifyMsg "$(_tg_header)
Status: <b>${last_pct:-0%} (failed)</b>"

            local err_file="${ANDROID_BUILD_TOP}/out/error.log"
            [ -s "${err_file}" ] && upload_log "${err_file}"
        fi

        return "${ec}"
    else
        command m "$@"
    fi
}

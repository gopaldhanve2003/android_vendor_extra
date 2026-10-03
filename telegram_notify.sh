#!/bin/bash
# telegram_notify.sh — optional; sourced by vendorsetup.sh only if present, so a
# checkout without it still builds, just silently.
# Needs: TG_TOKEN, TG_CID (bot token + chat id), curl, jq.
# Uses TARGET_PRODUCT / TARGET_BUILD_VARIANT (set by breakfast/lunch) and
# PROJECT / RELEASE_VERSION (set by vendorsetup.sh).

# notifyMsg <html> — first call sends and remembers $msg_id, later calls edit that message
notifyMsg() {
    local ep=sendMessage extra=() resp
    [ -n "${msg_id}" ] && { ep=editMessageText; extra=(-d message_id="${msg_id}"); }
    resp=$(curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/${ep}" \
           -d chat_id="${TG_CID}" -d parse_mode="HTML" -d link_preview_options='{"is_disabled":true}' \
           "${extra[@]}" -d text="$1")
    jq -e '.ok' <<< "${resp}" >/dev/null 2>&1 ||
        { echo "[TELEGRAM] ${ep} failed: $(jq -r '.description // "no response"' <<< "${resp}" 2>/dev/null)" >&2; return 0; }
    [ -n "${msg_id}" ] || msg_id=$(jq -r '.result.message_id' <<< "${resp}")
}

# upload_log <file> — sent as a reply to the status message ($msg_id)
upload_log() {
    local resp
    resp=$(curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendDocument" \
           -F chat_id="${TG_CID}" -F reply_to_message_id="${msg_id}" -F document=@"$1")
    jq -e '.ok' <<< "${resp}" >/dev/null 2>&1 ||
        echo "[TELEGRAM] upload failed: $(jq -r '.description // "no response"' <<< "${resp}" 2>/dev/null)" >&2
}

# Header for every message. BUILD_DEVICE / BUILD_VARIANT / BUILD_TYPE are set in m() and
# outlive it (download_watch reads them later). release() may change BUILD_TYPE, e.g. back
# to Testing when an OTA PR is still open.
tg_header() {
    echo "<b>${PROJECT}-${RELEASE_VERSION}</b>
Build started for ${BUILD_DEVICE}
Flavour: ${BUILD_VARIANT} | Release: ${TARGET_BUILD_VARIANT}
Type: ${BUILD_TYPE:-Testing}"
}

# tg_status "<text>" ["extra lines"] — header + "Status: <text>" (+ extra), sent or edited
tg_status() {
    notifyMsg "$(tg_header)
Status: <b>$1</b>${2:+
$2}"
}

# tg_prog <log> — last "NN% x/y" in the build log, as "NN% (x/y)"
tg_prog() { grep -Po '\d+% \d+/\d+' "$1" | tail -n1 | sed -e 's/ / (/' -e 's/$/)/'; }

# DEBUG trap set after a successful build. Posts the fallback final message when something
# other than release() sets $DOWNLOAD_URL (release() posts its own and sets REL_FINAL_SENT).
download_watch() {
    [ -n "${DOWNLOAD_URL:-}" ] || return 0
    if [ -z "${REL_FINAL_SENT:-}" ] && [ -n "${msg_id}" ]; then
        tg_status "${LAST_PCT:-100%} (completed)" "<b><a href=\"${DOWNLOAD_URL}\">DOWNLOAD</a></b>"
    fi
    trap - DEBUG
}

# Wrap `m bacon`. `m` isn't a shell function in this tree (envsetup.sh unsets it; it
# resolves via PATH to build/soong/bin/m after breakfast/lunch), so there's nothing to
# capture: define our own and call the real one with `command m`.
m() {
    [[ "$1" == "bacon" ]] || { command m "$@"; return; }

    BUILD_VARIANT="Vanilla"; [ "${WITH_GMS}" = "true" ] && BUILD_VARIANT="GMS"
    BUILD_DEVICE="${TARGET_PRODUCT#*_}"
    unset msg_id DOWNLOAD_URL LAST_PCT REL_FINAL_SENT
    # same values release() accepts; release() may downgrade Production later
    case "${RELEASE_PROD:-}" in 1|true) BUILD_TYPE="Production" ;; *) BUILD_TYPE="Testing" ;; esac
    notifyMsg "$(tg_header)"

    local log_file prog last_prog="" last_ts=0 now ec build_pid
    log_file=$(mktemp)
    ( set -o pipefail; command m "$@" 2>&1 | tee "${log_file}" ) &
    build_pid=$!

    while kill -0 "${build_pid}" 2>/dev/null; do
        prog=$(tg_prog "${log_file}")
        if [[ -n "${prog}" && "${prog}" != "${last_prog}" ]]; then
            LAST_PCT="${prog%% *}"
            now=$(date +%s)
            if (( now - last_ts >= 5 )); then
                tg_status "${prog}"
                last_ts="${now}"
            fi
            last_prog="${prog}"
        fi
        sleep 1
    done

    wait "${build_pid}"; ec=$?
    prog=$(tg_prog "${log_file}"); [ -n "${prog}" ] && LAST_PCT="${prog%% *}"
    rm -f "${log_file}"

    if [ "${ec}" -eq 0 ]; then
        trap 'download_watch' DEBUG
    else
        tg_status "${LAST_PCT:-0%} (failed)"
        local err_file="${ANDROID_BUILD_TOP}/out/error.log"
        [ -s "${err_file}" ] && upload_log "${err_file}"
    fi
    return "${ec}"
}

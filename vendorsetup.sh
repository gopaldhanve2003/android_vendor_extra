#!/bin/bash
# vendorsetup.sh — auto-sourced by `source build/envsetup.sh`
# Purpose: auto-detect build vars + apply_patches, both always needed.
# release <device> (test upload / GitHub release + OTA json) is defined below.
# Telegram notifications/progress are optional — only wired in if
# telegram_notify.sh exists next to this file, so a checkout without it
# still builds normally, just without notifications.

#######################################
# 1. Auto-detect ANDROID_BUILD_TOP / PROJECT / RELEASE_VERSION
#######################################
if [ -z "${ANDROID_BUILD_TOP}" ]; then
    TOP_DIR=$(git rev-parse --show-toplevel 2>/dev/null)
    if [ -d "${TOP_DIR}/.repo" ]; then
        export ANDROID_BUILD_TOP="${TOP_DIR}"
    elif [ -d "$(pwd)/.repo" ]; then
        export ANDROID_BUILD_TOP="$(pwd)"
    fi
fi

if [ -d "${ANDROID_BUILD_TOP}/.repo" ]; then
    DEFAULT_MANIFEST="${ANDROID_BUILD_TOP}/.repo/manifests/default.xml"
    if [ -f "${DEFAULT_MANIFEST}" ]; then
        DETECTED_REV=$(grep -oP '(?<=revision="refs/heads/)[^"]+' "${DEFAULT_MANIFEST}" | head -1)
        [ -z "${DETECTED_REV}" ] && DETECTED_REV=$(grep -oP '(?<=revision=")[^"]+' "${DEFAULT_MANIFEST}" | head -1)
    fi
    export PROJECT=$(echo "${DETECTED_REV}" | cut -d- -f1 | sed 's/./\U&/')
    export RELEASE_VERSION=$(echo "${DETECTED_REV}" | grep -oP '\d+\.\d+' || echo "1.0")
fi

#######################################
# 2. Apply local patches — call manually, e.g. `apply_patches` before
#    `m bacon`, when vendor/extra/patches exists.
#######################################
apply_patches() {
    local patches_path="${ANDROID_BUILD_TOP}/vendor/extra/patches"
    if [ ! -d "${patches_path}" ]; then
        echo "[ERROR] ${patches_path} not found."
        return 1
    fi

    local project_name project_path
    for project_name in $(cd "${patches_path}" && echo */); do
        project_path="$(tr _ / <<< "${project_name%/}")"
        cd "${ANDROID_BUILD_TOP}/${project_path}" 2>/dev/null || {
            echo "[ERROR] ${project_path} not found. Skipping."
            continue
        }
        echo "[INFO] Applying patches for ${project_name%/} on $(git rev-parse --short HEAD)"
        if ! git am "${patches_path}/${project_name}"*.patch --no-gpg-sign; then
            echo "[ERROR] Failed to apply patches for ${project_name%/}. Aborting am."
            git am --abort &> /dev/null
        fi
        cd "${ANDROID_BUILD_TOP}"
    done
}

#######################################
# 2b. Auto-apply patches on lunch, and set the gms build id, only when
#     the requested lunch target is lineage_*
#######################################
if declare -f lunch > /dev/null; then
    eval "_extra_orig_lunch() $(declare -f lunch | tail -n +2)"
    lunch() {
        if [[ "$1" == lineage_* ]]; then
            if [ "${WITH_GMS}" = "true" ]; then
                export TARGET_UNOFFICIAL_BUILD_ID=gms
            else
                unset TARGET_UNOFFICIAL_BUILD_ID
            fi
        fi
        _extra_orig_lunch "$@"
        [[ "$1" == lineage_* ]] || return 0
        apply_patches
    }
fi

#######################################
# 3. Optional Telegram notifications / progress monitoring.
#    Only loaded if telegram_notify.sh is present next to this file —
#    if it's missing, `m` is left untouched and the build still works.
#######################################
_VENDORSETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${_VENDORSETUP_DIR}/telegram_notify.sh" ]; then
    source "${_VENDORSETUP_DIR}/telegram_notify.sh"
fi

#######################################
# 4. release — test upload by default; RELEASE_PROD=1 (or true) publishes
#    to GitHub release assets + the OTA json (PR). Run it after the build:
#    breakfast / m installclean / m bacon stay in the build script.
#######################################
#   release <device>              find the built zip, test upload (DEFAULT)
#   RELEASE_PROD=1 release <device>   zip + $RELEASE_IMAGES become assets of a GitHub
#                             release (tag <device>-<UTC date_time>, target $OTA_BASE);
#                             the OTA json goes in a PR from branch ota-<device>[_gms] —
#                             merging it updates <device>.json. While that PR is open,
#                             RELEASE_PROD=1 turns into a TEST upload (merge/close the
#                             PR to release again).
# Env: RELEASE_PROD=1|true (set before the build so m()'s Telegram header can show it
#      too) | OTA_REPO | OTA_BASE (default main) | GITHUB_TOKEN (needed when producing)
#      RELEASE_IMAGES (set by the build script, e.g. "recoveryimage": must already be in $OUT)
#      GOFILE_TOKEN (optional) | test_upload() (optional hook replacing the gofile upload)
# Needs: jq, curl, unzip, git.

OTA_REPO="${OTA_REPO:-gopaldhanve2003/lineage_OTA}"
OTA_BASE="${OTA_BASE:-main}"

# rel_log INFO|WARN|ERROR <msg>
rel_log() {
    local c=32; [ "$1" = WARN ] && c=33; [ "$1" = ERROR ] && c=31
    echo -e "\e[${c}m[$1]\e[0m ${*:2}" >&2
}

# rel_curl <curl args> — GitHub API call; the token is passed to curl on stdin (-K -),
# not on the command line, so it never shows up in the process list.
rel_curl() { curl -sS -K - "$@" <<< "header = \"Authorization: Bearer ${GITHUB_TOKEN}\""; }

# rel_status "<text>" ["extra lines"] — only the text inside the parentheses is
# release's; the percentage is the build's own (LAST_PCT, set by m) — e.g.
# "Status: 100% (ready to release)", same shape as telegram_notify's
# "100% (completed)". No-op without telegram_notify.sh
rel_status() {
    declare -f notifyMsg >/dev/null || return 0
    notifyMsg "$(_tg_header)
Status: <b>${LAST_PCT:-100%} ($1)</b>${2:+
$2}"
}

release() {
    local device="" rc=0
    local api="https://api.github.com/repos/${OTA_REPO}"
    local ota_dir="${ANDROID_BUILD_TOP}/lineage_OTA"
    local zip filename json branch url dl dl_line resp f img tag release_id title pr_out pr_url
    local metadata sha256 romtype size version datetime os_patch_level os_sdk_level ota_property_files ota_entry

    device="$1"
    case "${device}" in
        ""|-*) echo "Usage: release <device>   (RELEASE_PROD=1 or true for production, default: test upload)"; return 1 ;;
    esac
    [ $# -le 1 ] || rel_log WARN "Ignoring extra arguments: ${*:2} (production is selected with RELEASE_PROD=1)."

    local prod="" reason=""
    case "${RELEASE_PROD:-}" in
        1|true) prod=1 ;;
    esac

    BUILD_TYPE="Testing"; [ -n "${prod}" ] && BUILD_TYPE="Production"   # shown in the Telegram header

    zip=$(find "${OUT:-${ANDROID_BUILD_TOP}/out/target/product/${device}}" -maxdepth 1 -type f \
        -iname "*.zip" ! -iname "*ota*.zip" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
    if [ ! -f "${zip}" ]; then
        rel_log ERROR "No ROM zip found!"
        rel_status "failed - no ROM zip"
        return 1
    fi
    filename=$(basename "${zip}")
    json="${device}.json"; [[ "${filename}" =~ gms ]] && json="${device}_gms.json"
    branch="ota-${json%.json}"

    # One OTA PR at a time per json: while a PR from ${branch} is open (or the
    # check fails), production is refused and this becomes a test upload.
    if [ -n "${prod}" ]; then
        [ -n "${GITHUB_TOKEN}" ] || { rel_log ERROR "GITHUB_TOKEN is not set."; return 1; }
        resp=$(rel_curl "${api}/pulls?state=open&base=${OTA_BASE}&head=${OTA_REPO%%/*}:${branch}")
        if ! jq -e 'type == "array"' <<< "${resp}" >/dev/null 2>&1; then
            reason="switched to testing as PR check failed"
            rel_log WARN "Could not check open PRs on ${OTA_REPO}."
        elif [ "$(jq length <<< "${resp}")" -gt 0 ]; then
            pr_url=$(jq -r '.[0].html_url' <<< "${resp}")
            reason="switched to testing as <a href=\"${pr_url}\">PR was open</a>"
            rel_log WARN "PR $(jq -r '.[0] | "#\(.number) (\(.html_url))"' <<< "${resp}") from ${branch} is still open — merge or close it before a production release."
        fi
        [ -n "${reason}" ] && { rel_log WARN "Switching to TEST."; prod=""; BUILD_TYPE="Testing"; }
    fi

    # ---- TEST: gofile (or your test_upload hook)
    if [ -z "${prod}" ]; then
        rel_log INFO "Release for ${device}: TEST"
        if declare -f test_upload >/dev/null; then
            url=$(test_upload "${zip}")
        else
            url=$({ [ -z "${GOFILE_TOKEN}" ] || echo "header = \"Authorization: Bearer ${GOFILE_TOKEN}\""; } |
                curl -s -S -K - -F "file=@${zip}" https://upload.gofile.io/uploadfile | jq -r '.data.downloadPage // empty')
        fi
        [ -n "${url}" ] || { rel_log ERROR "Test upload failed."; return 1; }
        rel_log INFO "Uploaded (test): ${url}"
        rel_status "${reason:-ready to test}" "<b><a href=\"${url}\">DOWNLOAD</a></b>"
        REL_FINAL_SENT=1   # final message posted — telegram_notify's _download_watch must not overwrite it
        DOWNLOAD_URL="${url}"
        echo "${url}"
        return 0
    fi

    # ---- PROD: GitHub release with the zip + images
    rel_log INFO "Release for ${device}: PRODUCTION (GitHub + PR)"
    rel_status "uploading to GitHub"
    tag="${device}-$(date -u +%Y%m%d_%H%M%S)"
    release_id=$(rel_curl -X POST "${api}/releases" \
        -d "$(jq -n --arg t "${tag}" --arg b "${OTA_BASE}" --arg d "Build: $(date)" \
            '{tag_name: $t, target_commitish: $b, name: $t, body: $d}')" | jq -r '.id // empty')
    if [ -z "${release_id}" ]; then
        rel_log ERROR "Failed to create GitHub release on ${OTA_REPO}."
        rel_status "failed - GitHub release"
        return 1
    fi

    declare -A image_map=(
        ["bootimage"]="${OUT}/boot.img"
        ["recoveryimage"]="${OUT}/recovery.img"
    )
    local files=("${zip}")
    for img in ${RELEASE_IMAGES:-}; do files+=("${image_map[${img}]}"); done

    for f in "${files[@]}"; do
        [ -f "${f}" ] || { rel_log WARN "${f:-unknown release image} not found, skipping."; continue; }
        rel_log INFO "Uploading $(basename "${f}") to ${OTA_REPO} release ${tag}..."
        resp=$(rel_curl -T "${f}" -H "Content-Type: application/octet-stream" \
            "https://uploads.github.com/repos/${OTA_REPO}/releases/${release_id}/assets?name=$(basename "${f}")")
        url=$(jq -r '.browser_download_url // empty' <<< "${resp}")
        if [ -z "${url}" ]; then
            rel_log ERROR "Failed to upload $(basename "${f}"): $(jq -r '.message // empty' <<< "${resp}" 2>/dev/null | head -c 300)"
            [ "${f}" = "${zip}" ] && { rel_status "failed - upload"; return 1; }
            continue
        fi
        [ "${f}" = "${zip}" ] && dl="${url}"
    done
    dl_line="<b><a href=\"${dl}\">DOWNLOAD</a></b>"

    # ---- OTA json (Adarsh's format), url = the GitHub asset
    get_prop() {
        grep -h "^$1=" "${OUT}/system/build.prop" "${OUT}/product/etc/build.prop" 2>/dev/null |
            head -1 | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    }
    metadata=$(unzip -p "${zip}" META-INF/com/android/metadata 2>/dev/null)
    get_meta() {
        grep -m1 "^$1=" <<< "${metadata}" | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    }

    sha256=$(awk '{print $1}' "${zip}.sha256sum" 2>/dev/null || sha256sum "${zip}" | awk '{print $1}')
    romtype=$(get_prop 'ro.lineage.releasetype')
    size=$(stat -c%s "${zip}")
    version=$(get_prop 'ro.lineage.build.version')
    datetime=$(get_prop 'ro.build.date.utc')
    os_patch_level=$(get_meta 'post-security-patch-level')
    os_sdk_level=$(get_meta 'post-sdk-level')
    ota_property_files=$(get_meta 'ota-property-files')

    if [ -z "${datetime}" ] || [ -z "${version}" ] || [ -z "${os_sdk_level}" ]; then
        rel_log ERROR "Failed to read build.prop / metadata values for ${filename} (is OUT set by breakfast?)."
        rel_status "release uploaded, OTA json failed" "${dl_line}"
        return 1
    fi
    [ -n "${ota_property_files}" ] ||
        rel_log WARN "ota-property-files missing from ${filename} metadata. Streaming updates will be unavailable."

    ota_entry=$(jq -n \
        --argjson datetime "${datetime}" \
        --arg filename "${filename}" \
        --arg os_patch_level "${os_patch_level}" \
        --argjson os_sdk_level "${os_sdk_level}" \
        --arg ota_property_files "${ota_property_files}" \
        --arg sha256 "${sha256}" \
        --argjson size "${size}" \
        --arg romtype "${romtype}" \
        --arg version "${version}" \
        --arg release_url "${dl}" \
        '[
            {
                datetime: $datetime,
                files: [
                    {
                        filename: $filename,
                        os_patch_level: $os_patch_level,
                        os_sdk_level: $os_sdk_level,
                        ota_property_files: $ota_property_files,
                        sha256: $sha256,
                        size: $size,
                        url: $release_url
                    } | with_entries(select(.value != ""))
                ],
                type: $romtype,
                version: $version
            }
        ]')

    # ---- json -> branch ota-<device> (extends existing branch if it still
    # exists remotely — e.g. a PR was closed without merging, or merged
    # branches aren't auto-deleted — otherwise starts fresh from OTA_BASE) -> PR
    # git gets the token through the environment (credential helper), not via the URL / argv / .git/config
    rel_cred() { GITHUB_TOKEN="${GITHUB_TOKEN}" GIT_TERMINAL_PROMPT=0 git -c credential.helper= \
        -c credential.helper='!f() { echo username=x-access-token; echo "password=${GITHUB_TOKEN}"; }; f' "$@"; }
    rel_git() { rel_cred -C "${ota_dir}" "$@"; }
    title="${device}: OTA update $(date +%F)"
    rm -rf "${ota_dir}"
    if ! rel_cred clone -q "https://github.com/${OTA_REPO}.git" "${ota_dir}"; then
        rel_log ERROR "Failed to clone ${OTA_REPO}."
        rel_status "release uploaded, OTA json failed" "${dl_line}"
        rm -rf "${ota_dir}"
        return 1
    fi
    
    git -C "${ota_dir}" config user.name "${NAME}"
    git -C "${ota_dir}" config user.email "${MAIL}"
    
    if ! rel_git checkout -q -B "${branch}" "origin/${branch}" 2>/dev/null &&
       ! rel_git checkout -q -B "${branch}" "origin/${OTA_BASE}"; then
        rel_log ERROR "Could not find branch ${branch} or ${OTA_BASE} (does ${OTA_BASE} have a first commit?)."
        rel_status "release uploaded, OTA json failed" "${dl_line}"
        rm -rf "${ota_dir}"
        return 1
    fi
    echo "${ota_entry}" > "${ota_dir}/${json}"
    rel_git add "${json}"

    if rel_git diff --cached --quiet; then
        rel_log WARN "${json} unchanged, no PR needed."
        rel_status "release complete - json unchanged" "${dl_line}"
    elif ! { rel_git commit -q -m "${title}" && rel_git push -q origin "${branch}"; }; then
        rel_log ERROR "git push failed."
        rel_status "release uploaded, PR failed" "${dl_line}"
        rc=1
    else
        pr_out=$(rel_curl -X POST "${api}/pulls" \
            -d "$(jq -n --arg t "${title}" --arg h "${branch}" --arg b "${OTA_BASE}" \
                --arg d "Automated OTA update for ${device}." '{title: $t, head: $h, base: $b, body: $d}')")
        pr_url=$(jq -r '.html_url // empty' <<< "${pr_out}" 2>/dev/null)
        if [ -n "${pr_url}" ]; then
            rel_log INFO "PR: ${pr_url}"
            rel_status "<a href=\"${pr_url}\">ready to release</a>" "${dl_line}"
        else
            rel_log ERROR "Failed to open PR. Check GITHUB_TOKEN scope/permissions."
            echo "${pr_out}" >&2
            rel_status "release uploaded, PR failed" "${dl_line}"
            rc=1
        fi
    fi
    rm -rf "${ota_dir}"

    REL_FINAL_SENT=1   # final message posted — telegram_notify's _download_watch must not overwrite it
    DOWNLOAD_URL="${dl}"
    echo "${dl}"
    return ${rc}
}

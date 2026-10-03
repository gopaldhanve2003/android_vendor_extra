#!/bin/bash
# vendorsetup.sh — auto-sourced by `source build/envsetup.sh`
# Auto-detects build vars, applies local patches on lunch, and defines release().
# Telegram notifications are optional: loaded only if telegram_notify.sh sits next to this file.

#######################################
# 1. Auto-detect ANDROID_BUILD_TOP / PROJECT / RELEASE_VERSION
#######################################
if [ -z "${ANDROID_BUILD_TOP}" ]; then
    _top=$(git rev-parse --show-toplevel 2>/dev/null)
    [ -d "${_top}/.repo" ] || _top="$(pwd)"
    [ -d "${_top}/.repo" ] && export ANDROID_BUILD_TOP="${_top}"
    unset _top
fi

if [ -d "${ANDROID_BUILD_TOP}/.repo" ]; then
    _manifest="${ANDROID_BUILD_TOP}/.repo/manifests/default.xml"
    if [ -f "${_manifest}" ]; then
        _rev=$(grep -oP '(?<=revision="refs/heads/)[^"]+' "${_manifest}" | head -1)
        [ -z "${_rev}" ] && _rev=$(grep -oP '(?<=revision=")[^"]+' "${_manifest}" | head -1)
    fi
    _name="${_rev%%-*}"
    PROJECT="${_name^}"
    RELEASE_VERSION=$(grep -oP '\d+\.\d+' <<< "${_rev}" || echo "1.0")
    export PROJECT RELEASE_VERSION
    unset _manifest _rev _name
fi

#######################################
# 2. Apply local patches (vendor/extra/patches/<path_with_underscores>/*.patch)
#######################################
apply_patches() {
    local patches_path="${ANDROID_BUILD_TOP}/vendor/extra/patches"
    if [ ! -d "${patches_path}" ]; then
        echo "[ERROR] ${patches_path} not found."
        return 1
    fi

    local patch_dir project_name project_path
    for patch_dir in "${patches_path}"/*/; do
        patch_dir="${patch_dir%/}"
        project_name="${patch_dir##*/}"
        project_path="${project_name//_//}"
        cd "${ANDROID_BUILD_TOP}/${project_path}" 2>/dev/null || {
            echo "[ERROR] ${project_path} not found. Skipping."
            continue
        }
        echo "[INFO] Applying patches for ${project_name} on $(git rev-parse --short HEAD)"
        if ! git am "${patch_dir}"/*.patch --no-gpg-sign; then
            echo "[ERROR] Failed to apply patches for ${project_name}. Aborting am."
            git am --abort &> /dev/null
        fi
        cd "${ANDROID_BUILD_TOP}" || return
    done
}

# lunch wrapper: for lineage_* targets only, set/unset the gms build id before lunch and
# apply patches after it succeeds. The eval copies the original lunch under a new name,
# the only way to wrap an existing shell function.
if declare -f lunch > /dev/null; then
    eval "extra_orig_lunch() $(declare -f lunch | tail -n +2)"
    lunch() {
        if [[ "$1" == lineage_* ]]; then
            if [ "${WITH_GMS}" = "true" ]; then
                export TARGET_UNOFFICIAL_BUILD_ID=gms
            else
                unset TARGET_UNOFFICIAL_BUILD_ID
            fi
        fi
        extra_orig_lunch "$@" || return
        [[ "$1" != lineage_* ]] || apply_patches
    }
fi

#######################################
# 3. Optional Telegram notifications
#######################################
_tg="$(dirname "${BASH_SOURCE[0]}")/telegram_notify.sh"
# shellcheck source=/dev/null
[ -f "${_tg}" ] && source "${_tg}"
unset _tg

#######################################
# 4. release <device>
#    default: test upload (gofile, or your test_upload() hook)
#    RELEASE_PROD=1|true: zip + $RELEASE_IMAGES go to a GitHub release on $OTA_REPO
#    (tag <device>-<UTC date_time>), and the OTA json goes in a PR from branch
#    ota-<device>[_gms]. If that PR is open or a production step fails, it falls back to a
#    test upload (reason in the status) and the unused GitHub release is deleted.
#    Env: OTA_REPO, OTA_BASE (default main), GITHUB_TOKEN, RELEASE_IMAGES (e.g.
#    "recoveryimage", must exist in $OUT), GOFILE_TOKEN (optional), NAME/MAIL (git identity).
#    Needs: jq, curl, unzip, git.
#    Helpers print results on stdout and log to stderr; release() alone talks to Telegram.
#######################################
OTA_REPO="${OTA_REPO:-gopaldhanve2003/lineage_OTA}"
OTA_BASE="${OTA_BASE:-main}"
REL_API="https://api.github.com/repos/${OTA_REPO}"

# rel_log INFO|WARN|ERROR <msg>
rel_log() {
    local c=32; [ "$1" = WARN ] && c=33; [ "$1" = ERROR ] && c=31
    printf '\e[%sm[%s]\e[0m %s\n' "${c}" "$1" "${*:2}" >&2
}

# rel_link <url> <text> — Telegram (HTML) link
rel_link() { echo "<a href=\"$1\">$2</a>"; }

# rel_status "<text>" ["extra lines"] — "Status: 100% (<text>)"; no-op without telegram_notify.sh
rel_status() {
    declare -f tg_status >/dev/null || return 0
    tg_status "${LAST_PCT:-100%} ($1)" "$2"
}

# rel_meta <key> <text> — trimmed value of a key=value line
rel_meta() { grep -m1 "^$1=" <<< "$2" | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

# rel_prop <key> — value from this build's build.prop
rel_prop() { rel_meta "$1" "$(cat "${OUT}/system/build.prop" "${OUT}/product/etc/build.prop" 2>/dev/null)"; }

# rel_curl <curl args> — GitHub API call; token goes to curl on stdin, never on argv
rel_curl() { curl -sS -K - "$@" <<< "header = \"Authorization: Bearer ${GITHUB_TOKEN}\""; }

# rel_cred <git args> — git with the token supplied by a credential helper, never in the
# URL/argv/.git/config (the first empty credential.helper clears inherited helpers)
rel_cred() {
    GITHUB_TOKEN="${GITHUB_TOKEN}" GIT_TERMINAL_PROMPT=0 git -c credential.helper= \
        -c credential.helper='!f() { echo username=x-access-token; echo "password=${GITHUB_TOKEN}"; }; f' "$@"
}

# rel_gh_unpublish <tag> — deletes the release and its tag (a release deletion leaves the tag)
rel_gh_unpublish() {
    local tag="$1" id
    id=$(rel_curl "${REL_API}/releases/tags/${tag}" | jq -r '.id // empty')
    [ -n "${id}" ] && rel_curl -X DELETE "${REL_API}/releases/${id}" >/dev/null
    rel_curl -X DELETE "${REL_API}/git/refs/tags/${tag}" >/dev/null
    rel_log WARN "Deleted release ${tag} from ${OTA_REPO}."
}

# rel_gh_publish <tag> <zip> — creates the release, uploads the zip and each $RELEASE_IMAGES
# file ("<name>image" -> $OUT/<name>.img; a missing/failed image only warns).
# Prints the zip's URL; fails if the release or the zip didn't make it.
rel_gh_publish() {
    local tag="$1" zip="$2" id f img name resp url zip_url
    local files=("${zip}")
    # RELEASE_IMAGES is a space-separated list, intentionally unquoted
    for img in ${RELEASE_IMAGES:-}; do files+=("${OUT}/${img%image}.img"); done

    id=$(rel_curl -X POST "${REL_API}/releases" \
        -d "$(jq -n --arg t "${tag}" --arg b "${OTA_BASE}" --arg d "Build: $(date)" \
            '{tag_name: $t, target_commitish: $b, name: $t, body: $d}')" | jq -r '.id // empty')
    [ -n "${id}" ] || { rel_log ERROR "Failed to create GitHub release on ${OTA_REPO}."; return 1; }

    for f in "${files[@]}"; do
        [ -f "${f}" ] || { rel_log WARN "${f} not found, skipping."; continue; }
        name=$(basename "${f}")
        rel_log INFO "Uploading ${name} to ${OTA_REPO} release ${tag}..."
        resp=$(rel_curl -T "${f}" -H "Content-Type: application/octet-stream" \
            "https://uploads.github.com/repos/${OTA_REPO}/releases/${id}/assets?name=${name}")
        url=$(jq -r '.browser_download_url // empty' <<< "${resp}")
        if [ -n "${url}" ]; then
            [ "${f}" = "${zip}" ] && zip_url="${url}"
        else
            rel_log ERROR "Failed to upload ${name}: $(jq -r '.message // empty' <<< "${resp}" 2>/dev/null | head -c 300)"
            [ "${f}" = "${zip}" ] && return 1
        fi
    done
    echo "${zip_url}"
}

# rel_ota_entry <zip> <url> — OTA json entry (Adarsh's format) for <zip> hosted at <url>
rel_ota_entry() {
    local zip="$1" url="$2" metadata sha256 romtype size version datetime
    local os_patch_level os_sdk_level ota_property_files
    metadata=$(unzip -p "${zip}" META-INF/com/android/metadata 2>/dev/null)

    sha256=$(awk '{print $1}' "${zip}.sha256sum" 2>/dev/null || sha256sum "${zip}" | awk '{print $1}')
    romtype=$(rel_prop 'ro.lineage.releasetype')
    size=$(stat -c%s "${zip}")
    version=$(rel_prop 'ro.lineage.build.version')
    datetime=$(rel_prop 'ro.build.date.utc')
    os_patch_level=$(rel_meta 'post-security-patch-level' "${metadata}")
    os_sdk_level=$(rel_meta 'post-sdk-level' "${metadata}")
    ota_property_files=$(rel_meta 'ota-property-files' "${metadata}")

    if [ -z "${datetime}" ] || [ -z "${version}" ] || [ -z "${os_sdk_level}" ]; then
        rel_log ERROR "Failed to read build.prop / metadata values for $(basename "${zip}") (is OUT set by breakfast?)."
        return 1
    fi
    [ -n "${ota_property_files}" ] ||
        rel_log WARN "ota-property-files missing from $(basename "${zip}") metadata. Streaming updates will be unavailable."

    jq -n \
        --argjson datetime "${datetime}" \
        --arg filename "$(basename "${zip}")" \
        --arg os_patch_level "${os_patch_level}" \
        --argjson os_sdk_level "${os_sdk_level}" \
        --arg ota_property_files "${ota_property_files}" \
        --arg sha256 "${sha256}" \
        --argjson size "${size}" \
        --arg romtype "${romtype}" \
        --arg version "${version}" \
        --arg release_url "${url}" \
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
        ]'
}

# rel_pr_check <branch> — prints why production must become a test upload (a PR from
# <branch> is open, or the check failed); prints nothing when production can go ahead
rel_pr_check() {
    local branch="$1" resp pr_url
    resp=$(rel_curl "${REL_API}/pulls?state=open&base=${OTA_BASE}&head=${OTA_REPO%%/*}:${branch}")
    if ! jq -e 'type == "array"' <<< "${resp}" >/dev/null 2>&1; then
        rel_log WARN "Could not check open PRs on ${OTA_REPO}."
        echo "switched to testing as PR check failed"
    elif [ "$(jq length <<< "${resp}")" -gt 0 ]; then
        pr_url=$(jq -r '.[0].html_url' <<< "${resp}")
        rel_log WARN "PR $(jq -r '.[0] | "#\(.number) (\(.html_url))"' <<< "${resp}") from ${branch} is still open — merge or close it before a production release."
        echo "switched to testing as $(rel_link "${pr_url}" "PR was open")"
    fi
}

# rel_ota_pr <device> <json> <branch> <entry> — clones the OTA repo into a temp dir on
# <branch> (the existing remote branch if there is one, else a new one from $OTA_BASE),
# commits <json>, pushes and opens the PR. Prints the Telegram status text; non-zero if the
# json/PR didn't happen. Runs in a subshell so the EXIT trap removes the temp dir on every path.
rel_ota_pr() (
    local device="$1" json="$2" branch="$3" entry="$4" dir resp pr_url
    local title; title="${device}: OTA update $(date +%F)"

    dir=$(mktemp -d) || return 1
    # shellcheck disable=SC2064  # expand ${dir} now, on purpose
    trap "rm -rf '${dir}'" EXIT

    rel_cred clone -q "https://github.com/${OTA_REPO}.git" "${dir}" ||
        { rel_log ERROR "Failed to clone ${OTA_REPO}."; echo "OTA json failed"; return 1; }
    cd "${dir}" || return 1
    rel_cred checkout -q -B "${branch}" "origin/${branch}" 2>/dev/null ||
    rel_cred checkout -q -B "${branch}" "origin/${OTA_BASE}" || {
        rel_log ERROR "Could not find branch ${branch} or ${OTA_BASE} (does ${OTA_BASE} have a first commit?)."
        echo "OTA json failed"; return 1
    }

    echo "${entry}" > "${json}"
    rel_cred add "${json}"
    if rel_cred diff --cached --quiet; then
        rel_log WARN "${json} unchanged, no PR needed."
        echo "json unchanged"; return 1
    fi
    { rel_cred -c user.name="${NAME}" -c user.email="${MAIL}" commit -q -m "${title}" &&
      rel_cred push -q origin "${branch}"; } || {
        rel_log ERROR "git push failed."
        echo "PR failed"; return 1
    }

    resp=$(rel_curl -X POST "${REL_API}/pulls" \
        -d "$(jq -n --arg t "${title}" --arg h "${branch}" --arg b "${OTA_BASE}" --arg d "Automated OTA update for ${device}." \
            '{title: $t, head: $h, base: $b, body: $d}')")
    pr_url=$(jq -r '.html_url // empty' <<< "${resp}" 2>/dev/null)
    [ -n "${pr_url}" ] || {
        rel_log ERROR "Failed to open PR. Check GITHUB_TOKEN scope/permissions."
        echo "${resp}" >&2
        echo "PR failed"; return 1
    }
    rel_log INFO "PR: ${pr_url}"
    rel_link "${pr_url}" "ready to release"
)

# release <device> — see the notes at the top of this section
release() {
    local device="$1" prod="" reason="" fail="" zip json branch tag dl ota_entry status rc=0
    case "${device}" in
        ""|-*) echo "Usage: release <device>   (RELEASE_PROD=1 or true for production, default: test upload)"; return 1 ;;
    esac
    case "${RELEASE_PROD:-}" in 1|true) prod=1 ;; esac
    BUILD_TYPE="Testing"; [ -n "${prod}" ] && BUILD_TYPE="Production"   # shown in the Telegram header

    # newest non-OTA-package zip in the build's output dir
    zip=$(find "${OUT:-${ANDROID_BUILD_TOP}/out/target/product/${device}}" -maxdepth 1 -type f \
        -iname "*.zip" ! -iname "*ota*.zip" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
    [ -f "${zip}" ] || { rel_log ERROR "No ROM zip found!"; rel_status "failed - no ROM zip"; return 1; }
    json="${device}.json"; [[ "${zip##*/}" =~ gms ]] && json="${device}_gms.json"
    branch="ota-${json%.json}"

    # one OTA PR at a time per json: while one is open (or the check fails), production
    # becomes a test upload
    if [ -n "${prod}" ]; then
        [ -n "${GITHUB_TOKEN}" ] || { rel_log ERROR "GITHUB_TOKEN is not set."; return 1; }
        reason=$(rel_pr_check "${branch}")
        [ -n "${reason}" ] && { rel_log WARN "Switching to TEST."; prod=""; BUILD_TYPE="Testing"; }
    fi

    # PROD: GitHub release, then OTA json -> PR. A failed step falls through to the test upload.
    if [ -n "${prod}" ]; then
        rel_log INFO "Release for ${device}: PRODUCTION (GitHub + PR)"
        rel_status "uploading to GitHub"
        tag="${device}-$(date -u +%Y%m%d_%H%M%S)"
        if ! dl=$(rel_gh_publish "${tag}" "${zip}"); then
            fail="GitHub upload failed"
        elif ! ota_entry=$(rel_ota_entry "${zip}" "${dl}"); then
            fail="OTA json failed"
        elif ! status=$(rel_ota_pr "${device}" "${json}" "${branch}" "${ota_entry}"); then
            fail="${status:-PR failed}"
        fi
        if [ -n "${fail}" ]; then
            rel_log WARN "Production failed (${fail}). Switching to TEST."
            prod=""; BUILD_TYPE="Testing"; reason="switched to testing as ${fail}"; rc=1
        fi
    fi

    # TEST: gofile (or your test_upload hook)
    if [ -z "${prod}" ]; then
        rel_log INFO "Release for ${device}: TEST"
        if declare -f test_upload >/dev/null; then
            dl=$(test_upload "${zip}")
        else
            dl=$({ [ -z "${GOFILE_TOKEN}" ] || echo "header = \"Authorization: Bearer ${GOFILE_TOKEN}\""; } |
                curl -s -S -K - -F "file=@${zip}" https://upload.gofile.io/uploadfile | jq -r '.data.downloadPage // empty')
        fi
        [ -n "${fail}" ] && rel_gh_unpublish "${tag}"   # the unused production release
        if [ -z "${dl}" ]; then
            rel_log ERROR "Test upload failed."
            rel_status "${fail:+production failed (${fail}), }test upload failed"
            return 1
        fi
        rel_log INFO "Uploaded (test): ${dl}"
        status="${reason:-ready to test}"
    fi

    rel_status "${status}" "<b>$(rel_link "${dl}" DOWNLOAD)</b>"
    REL_FINAL_SENT=1   # final message already posted — download_watch must not overwrite it
    DOWNLOAD_URL="${dl}"
    echo "${dl}"
    return ${rc}
}

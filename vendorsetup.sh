#!/bin/bash
# vendorsetup.sh — auto-sourced by `source build/envsetup.sh`
# Purpose: auto-detect build vars + apply_patches, both always needed.
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
# 3. Optional Telegram notifications / progress monitoring.
#    Only loaded if telegram_notify.sh is present next to this file —
#    if it's missing, `m` is left untouched and the build still works.
#######################################
_VENDORSETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${_VENDORSETUP_DIR}/telegram_notify.sh" ]; then
    source "${_VENDORSETUP_DIR}/telegram_notify.sh"
fi

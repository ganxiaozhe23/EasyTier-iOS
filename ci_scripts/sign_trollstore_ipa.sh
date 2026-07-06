#!/bin/bash

set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INPUT_PATH="${1:-${PROJECT_DIR}/build/export}"
OUTPUT_IPA="${2:-${PROJECT_DIR}/build/EasyTier-iOS15-TrollStore.ipa}"
APP_ENTITLEMENTS="${PROJECT_DIR}/EasyTier/EasyTier.entitlements"
EXT_ENTITLEMENTS="${PROJECT_DIR}/EasyTierNetworkExtension/EasyTierNetworkExtension.entitlements"

if ! command -v ldid >/dev/null 2>&1; then
    echo "::error::ldid is not installed. Install ldid-procursus before signing."
    exit 1
fi

if [ -d "${INPUT_PATH}" ]; then
    INPUT_IPA="$(find "${INPUT_PATH}" -maxdepth 1 -type f -name "*.ipa" | sort | head -n 1)"
else
    INPUT_IPA="${INPUT_PATH}"
fi

if [ -z "${INPUT_IPA:-}" ] || [ ! -f "${INPUT_IPA}" ]; then
    echo "::error::No exported .ipa found at ${INPUT_PATH}"
    exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

/usr/bin/unzip -q "${INPUT_IPA}" -d "${TMP_DIR}"

APP_DIR="$(find "${TMP_DIR}/Payload" -maxdepth 1 -type d -name "*.app" | sort | head -n 1)"
if [ -z "${APP_DIR}" ] || [ ! -d "${APP_DIR}" ]; then
    echo "::error::Exported IPA does not contain Payload/*.app"
    exit 1
fi

if find "${APP_DIR}/PlugIns" -maxdepth 1 -type d -name "*Widget*.appex" 2>/dev/null | grep -q .; then
    echo "::error::Widget extension is still embedded in the TrollStore IPA."
    exit 1
fi

EXT_DIR="${APP_DIR}/PlugIns/EasyTierNetworkExtension.appex"
if [ ! -d "${EXT_DIR}" ]; then
    echo "::error::EasyTierNetworkExtension.appex is missing from the IPA."
    exit 1
fi

find "${APP_DIR}" -name "_CodeSignature" -type d -prune -exec rm -rf {} +
find "${APP_DIR}" -name "embedded.mobileprovision" -type f -delete

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1"
}

APP_EXECUTABLE="$(plist_value "${APP_DIR}/Info.plist" CFBundleExecutable)"
EXT_EXECUTABLE="$(plist_value "${EXT_DIR}/Info.plist" CFBundleExecutable)"
APP_BINARY="${APP_DIR}/${APP_EXECUTABLE}"
EXT_BINARY="${EXT_DIR}/${EXT_EXECUTABLE}"

if [ ! -f "${APP_BINARY}" ]; then
    echo "::error::Main app executable not found at ${APP_BINARY}"
    exit 1
fi

if [ ! -f "${EXT_BINARY}" ]; then
    echo "::error::Network extension executable not found at ${EXT_BINARY}"
    exit 1
fi

sign_binary() {
    local binary="$1"
    local entitlements="${2:-}"

    if [ -n "${entitlements}" ]; then
        ldid -S"${entitlements}" "${binary}"
    else
        ldid -S "${binary}"
    fi
}

while IFS= read -r candidate; do
    if [ "${candidate}" = "${APP_BINARY}" ] || [ "${candidate}" = "${EXT_BINARY}" ]; then
        continue
    fi

    if /usr/bin/file "${candidate}" | grep -q "Mach-O"; then
        sign_binary "${candidate}"
    fi
done < <(find "${APP_DIR}" -type f | sort)

sign_binary "${EXT_BINARY}" "${EXT_ENTITLEMENTS}"
sign_binary "${APP_BINARY}" "${APP_ENTITLEMENTS}"

mkdir -p "$(dirname "${OUTPUT_IPA}")"
rm -f "${OUTPUT_IPA}"
(
    cd "${TMP_DIR}"
    /usr/bin/zip -qry "${OUTPUT_IPA}" Payload
)

echo "Signed TrollStore IPA: ${OUTPUT_IPA}"

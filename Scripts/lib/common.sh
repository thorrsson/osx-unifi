#!/bin/bash

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
DIST="dist"
if [[ "${UNIFI_PACKAGING_SMOKE:-0}" == 1 ]]; then DIST=".build/packaging-smoke"; fi
APP="$DIST/UniFi Desktop.app"
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

require_xcode() {
    xcrun --find actool > /dev/null 2>&1 \
        || die "Xcode is required to compile the app icon (actool ships with Xcode, not the Command Line Tools). Install Xcode, or point DEVELOPER_DIR at it: export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer"
}

resolve_version() {
    local version="${1#v}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "Version must be three numeric components, for example 0.1.0."
    printf '%s' "$version"
}

require_release_credentials() {
    [[ -n "${UNIFI_SIGNING_IDENTITY:-}" && "$UNIFI_SIGNING_IDENTITY" != - ]] \
        || die "Set UNIFI_SIGNING_IDENTITY to a Developer ID Application identity; releases cannot use ad-hoc signing."
    if [[ -z "${UNIFI_NOTARY_PROFILE:-}" ]]; then
        [[ -n "${NOTARY_API_KEY_ID:-}" && -n "${NOTARY_API_ISSUER_ID:-}" && -n "${NOTARY_API_KEY_P8:-}" ]] \
            || die "Set UNIFI_NOTARY_PROFILE or all three NOTARY_API_KEY_ID, NOTARY_API_ISSUER_ID, NOTARY_API_KEY_P8 values."
    fi
}

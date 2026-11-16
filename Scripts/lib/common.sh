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

# The Icon Composer document compiles to Assets.car (the layered icon macOS 26 renders) plus a flat
# AppIcon.icns fallback; actool also names both in a partial plist that is merged into Info.plist.
compile_icon() {
    local app="$1" icon="Resources/AppIcon.icon" icon_plist deployment_target icon_log
    [[ -d "$icon" ]] || die "Missing $icon."
    require_xcode
    icon_plist="$(mktemp -t unifi-icon-plist)"
    deployment_target="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$app/Contents/Info.plist")"
    if ! icon_log="$(xcrun actool "$icon" --compile "$app/Contents/Resources" --app-icon AppIcon \
            --output-partial-info-plist "$icon_plist" --platform macosx \
            --minimum-deployment-target "$deployment_target" --errors --warnings 2>&1)"; then
        rm -f "$icon_plist"
        printf '%s\n' "$icon_log" >&2
        die "actool could not compile $icon."
    fi
    [[ -f "$app/Contents/Resources/Assets.car" && -f "$app/Contents/Resources/AppIcon.icns" ]] \
        || die "actool did not produce Assets.car and AppIcon.icns from $icon."
    /usr/libexec/PlistBuddy -c "Merge $icon_plist" "$app/Contents/Info.plist"
    rm -f "$icon_plist"
}

# The Mac App Store build is branded separately; the DMG and Homebrew builds keep the name above.
APP_STORE_NAME="Lanyard"
APP_STORE_BUNDLE_ID="com.thorrsson.lanyard"
APP_STORE_APP="$DIST/$APP_STORE_NAME.app"

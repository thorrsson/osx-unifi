#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
version="$(resolve_version "${1:-0.1.0}")"
build_number="${UNIFI_BUILD_NUMBER:-$(git rev-list --count HEAD)}"
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || die "Build number must be a positive integer."
identity="${UNIFI_SIGNING_IDENTITY:--}"
build_args=(-c release --product UniFiDesktop)
if [[ "${UNIFI_UNIVERSAL:-0}" == 1 ]]; then
    build_args+=(--arch arm64 --arch x86_64)
fi
swift build "${build_args[@]}"
bin_path="$(swift build "${build_args[@]}" --show-bin-path)"
app="$APP"
if [[ -d "$app" ]]; then rm -rf "$app"; fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/UniFiDesktop" "$app/Contents/MacOS/UniFiDesktop"
cp Resources/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app/Contents/Info.plist"
# The Icon Composer document compiles to Assets.car (the layered icon macOS 26 renders) plus a flat
# AppIcon.icns fallback; actool also names both in a partial plist that is merged into Info.plist.
icon="Resources/AppIcon.icon"
[[ -d "$icon" ]] || die "Missing $icon."
require_xcode
icon_plist="$(mktemp -t unifi-icon-plist)"
trap 'rm -f "$icon_plist"' EXIT
deployment_target="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$app/Contents/Info.plist")"
if ! icon_log="$(xcrun actool "$icon" --compile "$app/Contents/Resources" --app-icon AppIcon \
        --output-partial-info-plist "$icon_plist" --platform macosx \
        --minimum-deployment-target "$deployment_target" --errors --warnings 2>&1)"; then
    printf '%s\n' "$icon_log" >&2
    die "actool could not compile $icon."
fi
[[ -f "$app/Contents/Resources/Assets.car" && -f "$app/Contents/Resources/AppIcon.icns" ]] \
    || die "actool did not produce Assets.car and AppIcon.icns from $icon."
/usr/libexec/PlistBuddy -c "Merge $icon_plist" "$app/Contents/Info.plist"
public_key="${UNIFI_SPARKLE_PUBLIC_ED_KEY:-}"
# An explicitly empty override disables updates in local-only artifacts.
if [[ -z "${UNIFI_SPARKLE_PUBLIC_ED_KEY+x}" && -f Resources/sparkle_ed_public_key.txt ]]; then
    public_key="$(cat Resources/sparkle_ed_public_key.txt)"
fi
feed="${UNIFI_SPARKLE_FEED_URL:-https://raw.githubusercontent.com/thorrsson/osx-unifi/main/appcast.xml}"
ruby Scripts/configure-updates.rb "$app/Contents/Info.plist" "$feed" "$public_key"
plutil -lint "$app/Contents/Info.plist"
[[ -d "$bin_path/Sparkle.framework" ]] || die "SwiftPM did not provide Sparkle.framework."
mkdir -p "$app/Contents/Frameworks"
ditto "$bin_path/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
sign_args=(--force)
if [[ -n "${UNIFI_SIGNING_KEYCHAIN:-}" ]]; then
    sign_args+=(--keychain "$UNIFI_SIGNING_KEYCHAIN")
fi
if [[ "$identity" == - ]]; then
    printf 'warning: local ad-hoc build only; not suitable for distribution.\n' >&2
    codesign --force --deep --sign - --timestamp=none "$app/Contents/Frameworks/Sparkle.framework"
    codesign --force --sign - --timestamp=none "$app"
else
    codesign "${sign_args[@]}" --deep --sign "$identity" --options runtime --timestamp \
        "$app/Contents/Frameworks/Sparkle.framework"
    codesign "${sign_args[@]}" --sign "$identity" --options runtime --timestamp \
        --entitlements Resources/UniFiDesktop.entitlements "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"
if [[ "$identity" != - && -n "${UNIFI_TEAM_ID:-}" ]]; then
    signature="$(codesign -dv --verbose=4 "$app" 2>&1)"
    [[ "$signature" == *"TeamIdentifier=$UNIFI_TEAM_ID"* ]] || die "Signing identity does not match UNIFI_TEAM_ID."
fi
lipo -info "$app/Contents/MacOS/UniFiDesktop"
printf 'Built %s\n' "$app"

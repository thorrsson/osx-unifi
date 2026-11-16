#!/bin/bash
# Builds the sandboxed Mac App Store variant (without Sparkle) and its installer package.
# Without UNIFI_APP_STORE_SIGNING_IDENTITY it makes an ad-hoc signed, unsigned-package local build
# that exercises the sandbox but cannot be uploaded.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
version="$(resolve_version "${1:-0.1.0}")"
build_number="${UNIFI_BUILD_NUMBER:-$(git rev-list --count HEAD)}"
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || die "Build number must be a positive integer."
identity="${UNIFI_APP_STORE_SIGNING_IDENTITY:--}"
bundle_id="$APP_STORE_BUNDLE_ID"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/unifi-app-store.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

if [[ "$identity" != - ]]; then
    installer="${UNIFI_APP_STORE_INSTALLER_IDENTITY:-}"
    profile="${UNIFI_APP_STORE_PROFILE:-}"
    team="${UNIFI_TEAM_ID:-}"
    [[ -n "$installer" && "$installer" != - ]] \
        || die "Set UNIFI_APP_STORE_INSTALLER_IDENTITY to a Mac Installer Distribution identity."
    [[ "$team" =~ ^[A-Z0-9]{10}$ ]] || die "Set UNIFI_TEAM_ID to your 10-character Apple Developer Team ID."
    [[ -n "$profile" && -f "$profile" ]] \
        || die "Set UNIFI_APP_STORE_PROFILE to the Mac App Store provisioning profile (.provisionprofile) for $bundle_id."
    security cms -D -i "$profile" > "$scratch/profile.plist" 2> /dev/null \
        || die "UNIFI_APP_STORE_PROFILE is not a readable provisioning profile."
    profile_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$scratch/profile.plist" 2> /dev/null; }
    profile_app_id="$(profile_value 'Entitlements:com.apple.application-identifier' || true)"
    [[ "$profile_app_id" == "$team.$bundle_id" ]] \
        || die "The provisioning profile is for '${profile_app_id:-an unknown app}', not $team.$bundle_id."
    if profile_value ProvisionedDevices > /dev/null || profile_value ProvisionsAllDevices > /dev/null; then
        die "The provisioning profile is a development or Developer ID profile; create a Mac App Store distribution profile."
    fi
    expires="$(plutil -extract ExpirationDate raw -o - "$scratch/profile.plist")"
    [[ "$expires" > "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]] || die "The provisioning profile expired on $expires."
fi

build_args=(-c release --product UniFiDesktop --scratch-path .build/appstore)
if [[ "${UNIFI_UNIVERSAL:-1}" == 1 ]]; then
    build_args+=(--arch arm64 --arch x86_64)
fi
UNIFI_APP_STORE=1 swift build "${build_args[@]}"
bin_path="$(UNIFI_APP_STORE=1 swift build "${build_args[@]}" --show-bin-path)"
app="$APP_STORE_APP"
if [[ -d "$app" ]]; then rm -rf "$app"; fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/UniFiDesktop" "$app/Contents/MacOS/UniFiDesktop"
otool -L "$app/Contents/MacOS/UniFiDesktop" | grep -q Sparkle && die "The App Store build must not link Sparkle."
plist="$app/Contents/Info.plist"
cp Resources/Info.plist "$plist"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleIdentifier $bundle_id" \
    -c "Set :CFBundleShortVersionString $version" \
    -c "Set :CFBundleVersion $build_number" \
    -c "Set :CFBundleName $APP_STORE_NAME" \
    -c "Add :CFBundleDisplayName string $APP_STORE_NAME" \
    -c "Add :LSApplicationCategoryType string public.app-category.utilities" \
    -c "Add :ITSAppUsesNonExemptEncryption bool false" \
    "$plist"
cp Resources/PrivacyInfo.xcprivacy "$app/Contents/Resources/PrivacyInfo.xcprivacy"
compile_icon "$app"
plutil -lint "$plist"
if plutil -convert xml1 -o - "$plist" | grep -q '<key>SU'; then die "The App Store build must not configure Sparkle."; fi

entitlements="$scratch/app.entitlements"
cp Resources/AppStore.entitlements "$entitlements"
sign_args=(--force)
if [[ -n "${UNIFI_SIGNING_KEYCHAIN:-}" ]]; then
    sign_args+=(--keychain "$UNIFI_SIGNING_KEYCHAIN")
fi
if [[ "$identity" == - ]]; then
    printf 'warning: local ad-hoc build only; it cannot be uploaded to App Store Connect.\n' >&2
    codesign --force --sign - --timestamp=none --entitlements "$entitlements" "$app"
else
    /usr/libexec/PlistBuddy \
        -c "Add :com.apple.application-identifier string $team.$bundle_id" \
        -c "Add :com.apple.developer.team-identifier string $team" \
        "$entitlements"
    cp "$profile" "$app/Contents/embedded.provisionprofile"
    codesign "${sign_args[@]}" --sign "$identity" --options runtime --timestamp --entitlements "$entitlements" "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"
codesign -d --entitlements - --xml "$app" 2> /dev/null > "$scratch/signed.entitlements"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$scratch/signed.entitlements")" == true ]] \
    || die "The signed app is not sandboxed."
if [[ "$identity" != - ]]; then
    signature="$(codesign -dv --verbose=4 "$app" 2>&1)"
    [[ "$signature" == *"TeamIdentifier=$team"* ]] || die "Signing identity does not match UNIFI_TEAM_ID."
fi
lipo -info "$app/Contents/MacOS/UniFiDesktop"

pkg="$DIST/$APP_STORE_NAME-$version.pkg"
rm -f "$pkg"
pkg_args=(--component "$app" /Applications)
if [[ "$identity" != - ]]; then
    pkg_args+=(--sign "$installer")
    if [[ -n "${UNIFI_SIGNING_KEYCHAIN:-}" ]]; then pkg_args+=(--keychain "$UNIFI_SIGNING_KEYCHAIN"); fi
fi
productbuild "${pkg_args[@]}" "$pkg"
if [[ "$identity" != - ]]; then pkgutil --check-signature "$pkg"; fi
printf 'Built %s and %s\n' "$app" "$pkg"

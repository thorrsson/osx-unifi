#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
version="$(resolve_version "${1:-0.1.0}")"
[[ -d "$APP" ]] || die "Build the app before packaging."
bundled_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$bundled_version" == "$version" ]] || die "Requested version does not match the app bundle."
codesign --verify --strict "$APP"
staging="$(mktemp -d "${TMPDIR:-/tmp}/unifi-dmg.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto "$APP" "$staging/UniFi Desktop.app"
ln -s /Applications "$staging/Applications"
dmg="$DIST/UniFiDesktop-$version.dmg"
hdiutil create -volname "UniFi Desktop $version" -srcfolder "$staging" \
    -fs HFS+ -format UDZO -ov "$dmg"
identity="${UNIFI_SIGNING_IDENTITY:--}"
if [[ "$identity" != - ]]; then
    sign_args=(--force)
    if [[ -n "${UNIFI_SIGNING_KEYCHAIN:-}" ]]; then
        sign_args+=(--keychain "$UNIFI_SIGNING_KEYCHAIN")
    fi
    codesign "${sign_args[@]}" --sign "$identity" --timestamp "$dmg"
    codesign --verify --verbose=2 "$dmg"
else
    printf 'warning: unsigned local disk image; not suitable for distribution.\n' >&2
fi

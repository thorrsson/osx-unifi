#!/bin/bash
set +x
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
source Scripts/lib/sparkle.sh
version="$(resolve_version "${1:?Pass a version}")"
dmg="$DIST/UniFiDesktop-$version.dmg"
[[ -f "$dmg" ]] || die "Release disk image is missing."
[[ -n "${SPARKLE_PRIVATE_KEY:-}" ]] || die "Set SPARKLE_PRIVATE_KEY to sign the update."
umask 077
scratch="$(mktemp -d .build/appcast.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
printf '%s' "$SPARKLE_PRIVATE_KEY" > "$scratch/key"
mkdir "$scratch/feed"
cp "$dmg" "$scratch/feed/"
# The smoke check signs a throwaway 0.1.0 build, which the published feed's newer
# releases would push out of the generated appcast, so it starts from an empty feed.
if [[ "${UNIFI_PACKAGING_SMOKE:-0}" == 1 ]]; then
    :
elif git cat-file -e origin/main:appcast.xml 2>/dev/null; then
    git show origin/main:appcast.xml > "$scratch/feed/appcast.xml"
elif [[ -f appcast.xml ]]; then
    cp appcast.xml "$scratch/feed/appcast.xml"
fi
run_sparkle_tool generate_appcast --ed-key-file "$scratch/key" \
    --download-url-prefix "https://github.com/thorrsson/osx-unifi/releases/download/v$version/" \
    --maximum-versions 5 --maximum-deltas 0 "$scratch/feed"
cp "$scratch/feed/appcast.xml" "$DIST/appcast.xml"
# Verify the exact signed bytes against the public key embedded in the app.
public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")"
ruby Scripts/verify-appcast.rb "$DIST/appcast.xml" "$dmg" "$public_key"

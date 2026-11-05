#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
version="$(resolve_version "${1:?Pass a release version}")"
require_release_credentials
[[ -n "${SPARKLE_PRIVATE_KEY:-}" ]] || die "SPARKLE_PRIVATE_KEY is required for releases."
[[ -n "${UNIFI_SPARKLE_PUBLIC_ED_KEY:-}" || ( -z "${UNIFI_SPARKLE_PUBLIC_ED_KEY+x}" && -s Resources/sparkle_ed_public_key.txt ) ]] \
    || die "A Sparkle public key is required for releases."
public_key="${UNIFI_SPARKLE_PUBLIC_ED_KEY:-$(cat Resources/sparkle_ed_public_key.txt 2>/dev/null)}"
ruby Scripts/check-sparkle-keypair.rb "$public_key"
[[ -z "$(git status --porcelain)" ]] || die "Release from a clean checkout."
export UNIFI_UNIVERSAL=1
bash Scripts/test.sh
bash Scripts/build-app.sh "$version"
lipo "$APP/Contents/MacOS/UniFiDesktop" -verify_arch arm64 x86_64
# Staple the app before packaging so the installed app also carries its ticket.
bash Scripts/notarize.sh "$APP"
bash Scripts/make-dmg.sh "$version"
bash Scripts/notarize.sh "dist/UniFiDesktop-$version.dmg"
(cd dist && shasum -a 256 "UniFiDesktop-$version.dmg" > "UniFiDesktop-$version.dmg.sha256")
bash Scripts/generate-appcast.sh "$version"
printf 'Ready for distribution: dist/UniFiDesktop-%s.dmg\n' "$version"

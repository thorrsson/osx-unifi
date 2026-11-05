#!/bin/bash
# Validates and uploads a signed Mac App Store installer package to App Store Connect.
# Uses the same App Store Connect API key as notarization; the key needs the Developer role or higher.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
pkg="${1:?Pass the installer package built by Scripts/build-app-store.sh}"
[[ -f "$pkg" ]] || die "Installer package does not exist."
[[ -n "${NOTARY_API_KEY_ID:-}" && -n "${NOTARY_API_ISSUER_ID:-}" && -n "${NOTARY_API_KEY_P8:-}" ]] \
    || die "Set NOTARY_API_KEY_ID, NOTARY_API_ISSUER_ID, and NOTARY_API_KEY_P8 (base64) for App Store Connect."
signature="$(pkgutil --check-signature "$pkg" 2>&1)" || die "The installer package is not signed."
[[ "$signature" == *"3rd Party Mac Developer Installer:"* || "$signature" == *"Mac Installer Distribution:"* ]] \
    || die "The installer package must be signed with a Mac Installer Distribution identity."
umask 077
keys="$(mktemp -d "${TMPDIR:-/tmp}/unifi-asc.XXXXXX")"
trap 'rm -rf "$keys"' EXIT
printf '%s' "$NOTARY_API_KEY_P8" | base64 --decode > "$keys/AuthKey_$NOTARY_API_KEY_ID.p8"
openssl pkey -in "$keys/AuthKey_$NOTARY_API_KEY_ID.p8" -noout > /dev/null \
    || die "NOTARY_API_KEY_P8 must be a base64-encoded PKCS#8 private key."
auth=(--api-key "$NOTARY_API_KEY_ID" --api-issuer "$NOTARY_API_ISSUER_ID")
API_PRIVATE_KEYS_DIR="$keys" xcrun altool --validate-app "$pkg" "${auth[@]}"
API_PRIVATE_KEYS_DIR="$keys" xcrun altool --upload-package "$pkg" "${auth[@]}"
printf 'Uploaded %s. It appears in App Store Connect after processing.\n' "$pkg"

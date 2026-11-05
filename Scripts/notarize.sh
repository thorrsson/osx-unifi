#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
require_release_credentials
target="${1:?Pass the app or disk image to notarize}"
[[ -e "$target" ]] || die "Notarization target does not exist."
codesign --verify --strict "$target"
signature="$(codesign -dv --verbose=4 "$target" 2>&1)"
[[ "$signature" == *"Authority=Developer ID Application:"* ]] \
    || die "Notarization requires a Developer ID Application signature."
umask 077
scratch="$(mktemp -d "${TMPDIR:-/tmp}/unifi-notary.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
args=()
if [[ -n "${UNIFI_NOTARY_PROFILE:-}" ]]; then
    args=(--keychain-profile "$UNIFI_NOTARY_PROFILE")
else
    printf '%s' "$NOTARY_API_KEY_P8" | base64 --decode > "$scratch/AuthKey.p8"
    openssl pkey -in "$scratch/AuthKey.p8" -noout > /dev/null \
        || die "NOTARY_API_KEY_P8 must be a base64-encoded PKCS#8 private key."
    args=(--key "$scratch/AuthKey.p8" --key-id "$NOTARY_API_KEY_ID" --issuer "$NOTARY_API_ISSUER_ID")
fi
submission="$target"
if [[ -d "$target" ]]; then
    submission="$scratch/app.zip"
    ditto -c -k --keepParent "$target" "$submission"
fi
xcrun notarytool submit "$submission" "${args[@]}" --wait --timeout 30m \
    --output-format plist > "$scratch/result.plist"
status="$(/usr/libexec/PlistBuddy -c 'Print :status' "$scratch/result.plist")"
if [[ "$status" != Accepted ]]; then
    submission_id="$(/usr/libexec/PlistBuddy -c 'Print :id' "$scratch/result.plist")"
    xcrun notarytool log "$submission_id" "${args[@]}" >&2
    die "Apple did not accept the notarization submission."
fi
xcrun stapler staple "$target"
xcrun stapler validate "$target"
if [[ -d "$target" ]]; then
    spctl --assess --type execute --verbose=2 "$target"
else
    spctl --assess --type open --context context:primary-signature --verbose=2 "$target"
fi

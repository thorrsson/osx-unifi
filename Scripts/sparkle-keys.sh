#!/bin/bash
set +x
set -euo pipefail
if [[ "${1:-}" == --help ]]; then
    printf 'Usage: bash Scripts/sparkle-keys.sh generate|public|export PATH\nPrivate keys stay in the app-specific Keychain account unless explicitly exported.\n'
    exit 0
fi
source "$(dirname "$0")/lib/common.sh"
source Scripts/lib/sparkle.sh
account="com.thorrsson.osx-unifi.sparkle"
config="Resources/sparkle_ed_public_key.txt"
command="${1:-generate}"
case "$command" in
    generate)
        [[ $# -le 1 ]] || die "generate takes no arguments."
        [[ ! -s "$config" ]] || die "A public key already exists; refusing to replace a shipped update key."
        run_sparkle_tool generate_keys --account "$account" > /dev/null
        key="$(run_sparkle_tool generate_keys --account "$account" -p)"
        printf '%s\n' "$key" > "$config"
        printf 'Saved public key in %s. Commit it; keep the private key backed up securely.\n' "$config"
        ;;
    public|export)
        key="$(run_sparkle_tool generate_keys --account "$account" -p)"
        [[ ! -s "$config" || "$key" == "$(cat "$config")" ]] || die "Keychain key does not match configured public key."
        if [[ "$command" == public ]]; then
            [[ $# -eq 1 ]] || die "public takes no arguments."
            printf '%s\n' "$key"
        else
            [[ $# -eq 2 ]] || die "export requires a destination path."
            destination="$2"
            [[ ! -e "$destination" && ! -L "$destination" ]] || die "Refusing to overwrite an export destination."
            # Keep exports inside a known ignored folder, not accidentally in source.
            [[ "$destination" == .sparkle/* && "$destination" != *".."* ]] \
                || die "Export to .sparkle/private-key.txt (Git-ignored)."
            git check-ignore --quiet -- "$destination" || die "Export destination is not Git-ignored."
            umask 077
            mkdir -p .sparkle
            staging="$(mktemp -d .sparkle/export.XXXXXX)"
            trap 'rm -rf "$staging"' EXIT
            run_sparkle_tool generate_keys --account "$account" -x "$staging/key" > /dev/null
            [[ -s "$staging/key" && ! -L "$staging/key" ]] || die "Sparkle export failed."
            chmod 600 "$staging/key"
            ln "$staging/key" "$destination"
            printf 'Saved owner-only private-key export; never commit or share it.\n'
        fi
        ;;
    *) die "Use generate, public or export PATH." ;;
esac

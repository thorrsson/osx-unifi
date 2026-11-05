#!/bin/bash
# Pinned to the same Sparkle release as Package.swift.
SPARKLE_VERSION="2.9.6"
SPARKLE_ZIP_SHA256="8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606"

run_sparkle_tool() (
    set -euo pipefail
    tool="$1"
    shift
    case "$tool" in
        generate_keys|generate_appcast|sign_update) ;;
        *) die "Unsupported Sparkle tool." ;;
    esac
    mkdir -p .build/sparkle-tools
    staging="$(mktemp -d .build/sparkle-tools/run.XXXXXX)"
    trap 'rm -rf "$staging"' EXIT
    archive=".build/sparkle-tools/Sparkle-$SPARKLE_VERSION.zip"
    if [[ ! -f "$archive" ]]; then
        curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
            -o "$staging/download.zip" \
            "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-for-Swift-Package-Manager.zip"
        checksum="$(shasum -a 256 "$staging/download.zip")"
        [[ "${checksum%% *}" == "$SPARKLE_ZIP_SHA256" ]] || die "Sparkle tools checksum mismatch."
        mv "$staging/download.zip" "$archive"
    fi
    checksum="$(shasum -a 256 "$archive")"
    [[ "${checksum%% *}" == "$SPARKLE_ZIP_SHA256" ]] || die "Cached Sparkle tools checksum mismatch."
    unzip -q "$archive" 'bin/*' -d "$staging"
    "$staging/bin/$tool" "$@"
)

#!/bin/bash
# Adapted from ingram-report-native: dotenv is parsed as literal data, never sourced.
set +x
set -euo pipefail
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
root="$(cd "$(dirname "$0")/.." && pwd)"
env_file="$root/.env"
repo=""
dry_run=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--env-file)
            [[ $# -ge 2 && -n "$2" ]] || die "--env-file requires a path."
            env_file="$2"; shift 2 ;;
        -R|--repo)
            [[ $# -ge 2 && -n "$2" ]] || die "--repo requires OWNER/REPO."
            repo="$2"; shift 2 ;;
        -n|--dry-run) dry_run=1; shift ;;
        -h|--help)
            printf 'Usage: bash Scripts/setup-release-secrets.sh [-f .env] [-R OWNER/REPO] [--dry-run]\nThe release environment must already exist with reviewer/tag protection.\nOnly setting names are printed. Dotenv values are literal, not shell code.\n'
            exit 0 ;;
        *) die "Unknown argument; use --help." ;;
    esac
done
[[ -r "$env_file" && -f "$env_file" ]] || die "Cannot read dotenv file."
required=(
    MACOS_CERTIFICATE_P12 MACOS_CERTIFICATE_PASSWORD MACOS_SIGNING_IDENTITY MACOS_TEAM_ID
    NOTARY_API_KEY_ID NOTARY_API_ISSUER_ID NOTARY_API_KEY_P8
    SPARKLE_PRIVATE_KEY UNIFI_SPARKLE_FEED_URL
)
allowed=" ${required[*]} "
seen=" "
provided=" "
names=()
values=()
line_number=0
assignment='^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$'
trim() {
    REPLY="${1#"${1%%[![:space:]]*}"}"
    REPLY="${REPLY%"${REPLY##*[![:space:]]}"}"
}
while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    trim "$line"
    line="$REPLY"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" =~ $assignment ]] || die "Invalid assignment on line $line_number."
    name="${BASH_REMATCH[2]}"
    value="${BASH_REMATCH[3]}"
    [[ "$allowed" == *" $name "* ]] || die "Unknown release setting $name on line $line_number."
    [[ "$seen" != *" $name "* ]] || die "Duplicate setting $name on line $line_number."
    seen+="$name "
    trim "$value"
    value="$REPLY"
    case "$value" in
        \"*|\'*)
            quote="${value:0:1}"
            [[ ${#value} -ge 2 && "${value: -1}" == "$quote" ]] || die "Unmatched quote on line $line_number."
            value="${value:1:${#value}-2}"
            ;;
    esac
    [[ -n "$value" ]] || continue
    names+=("$name")
    values+=("$value")
    provided+="$name "
done < "$env_file"
for name in "${required[@]}"; do
    [[ "$provided" == *" $name "* ]] || die "$name must be set in the dotenv file."
done
export GH_PROMPT_DISABLED=1
unset GH_DEBUG
if [[ -z "$repo" ]]; then
    repo="$(cd "$root" && gh repo view --json nameWithOwner --jq .nameWithOwner)" \
        || die "Cannot resolve repository; pass --repo OWNER/REPO."
fi
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "Repository must be OWNER/REPO."
if [[ "$dry_run" == 0 ]]; then
    gh api --method GET "repos/$repo/environments/release" --silent \
        || die "Create and protect the release environment first; check gh authentication and permissions."
fi
for ((i = 0; i < ${#names[@]}; i++)); do
    kind=secret
    [[ "${names[$i]}" != UNIFI_SPARKLE_FEED_URL ]] || kind=variable
    if [[ "$dry_run" == 1 ]]; then
        printf 'Would set %s %s in %s/release\n' "$kind" "${names[$i]}" "$repo"
    else
        printf '%s' "${values[$i]}" | gh "$kind" set "${names[$i]}" --env release --repo "$repo" \
            || die "Failed to set $kind ${names[$i]}; earlier uploads may have succeeded."
        printf 'Set %s %s in %s/release\n' "$kind" "${names[$i]}" "$repo"
    fi
done

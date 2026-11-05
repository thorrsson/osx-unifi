#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
ruby Scripts/tests/release_test.rb
swift test "$@"

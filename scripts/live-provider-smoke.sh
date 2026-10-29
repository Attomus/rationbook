#!/bin/sh
# SPDX-License-Identifier: Apache-2.0

set -eu

repository=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

if [ "${RATIONBOOK_ALLOW_LIVE_PROVIDER_SMOKE:-}" != "1" ]; then
    echo "Live provider refresh is opt-in and may consume account capacity." >&2
    echo "Re-run with RATIONBOOK_ALLOW_LIVE_PROVIDER_SMOKE=1 after reviewing the command." >&2
    exit 64
fi

binary=${RATIONBOOK_BINARY:-"$repository/.build/release/rationbook"}
test -x "$binary" || {
    echo "Missing executable: $binary (run scripts/verify.sh first)" >&2
    exit 66
}

temporary_data=$(mktemp -d)
trap '/bin/rm -rf "$temporary_data"' EXIT HUP INT TERM

set +e
RATIONBOOK_DATA_DIR="$temporary_data" "$binary" status --refresh --json > "$temporary_data/status.json"
smoke_status=$?
set -e

case "$smoke_status" in
    0|2) ;;
    *) echo "Provider smoke failed with exit $smoke_status" >&2; exit "$smoke_status";;
esac

/usr/bin/python3 -m json.tool "$temporary_data/status.json" >/dev/null
echo "Live provider smoke passed (exit $smoke_status)"

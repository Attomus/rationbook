#!/bin/sh
# SPDX-License-Identifier: Apache-2.0

set -eu

if [ "$#" -ne 1 ]; then
    echo "Usage: scripts/check-public-source.sh EXPORTED_DIRECTORY" >&2
    exit 64
fi

repository=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
exec /usr/bin/env python3 "$repository/scripts/public_source.py" verify \
    --root "$1" \
    --allowlist scripts/public-source-allowlist.txt

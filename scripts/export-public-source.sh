#!/bin/sh
# SPDX-License-Identifier: Apache-2.0

set -eu

if [ "$#" -ne 1 ]; then
    echo "Usage: scripts/export-public-source.sh NEW_DESTINATION" >&2
    exit 64
fi

repository=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
exec /usr/bin/env python3 "$repository/scripts/public_source.py" export \
    --root "$repository" \
    --allowlist scripts/public-source-allowlist.txt \
    "$1"

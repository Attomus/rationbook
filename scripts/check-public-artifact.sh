#!/bin/sh
# SPDX-License-Identifier: Apache-2.0

set -eu

if [ "$#" -ne 1 ]; then
    echo "Usage: scripts/check-public-artifact.sh APP_OR_ARCHIVE" >&2
    exit 64
fi

repository=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
exec /usr/bin/env python3 "$repository/scripts/public_source.py" scan-artifact "$1"

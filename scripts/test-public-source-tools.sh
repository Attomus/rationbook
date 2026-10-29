#!/bin/sh
# SPDX-License-Identifier: Apache-2.0

set -eu

repository=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
exec /usr/bin/env python3 "$repository/scripts/public_source.py" self-test

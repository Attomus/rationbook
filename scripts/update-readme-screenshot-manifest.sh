#!/bin/sh
# SPDX-License-Identifier: Apache-2.0

set -eu

repository=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
manifest="$repository/docs/screenshots/UI_SOURCE_SHA256"

for image in \
    rationbook-essential-light.png \
    rationbook-full-dark.png \
    rationbook-settings-dark.png \
    rationbook-menubar.png
do
    test -s "$repository/docs/screenshots/$image" || {
        echo "Capture docs/screenshots/$image before approving the screenshot set." >&2
        exit 1
    }
done

{
    for image in \
        rationbook-essential-light.png \
        rationbook-full-dark.png \
        rationbook-settings-dark.png \
        rationbook-menubar.png
    do
        digest=$(shasum -a 256 "$repository/docs/screenshots/$image" | awk '{print $1}')
        printf '%s\t%s\n' "$image" "$digest"
    done
} > "$manifest"
echo "Recorded reviewed README screenshot checksums"

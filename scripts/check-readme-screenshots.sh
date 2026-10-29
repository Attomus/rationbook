#!/bin/sh
# SPDX-License-Identifier: Apache-2.0

set -eu

repository=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
manifest="$repository/docs/screenshots/UI_SOURCE_SHA256"
required_images="
rationbook-essential-light.png
rationbook-full-dark.png
rationbook-settings-dark.png
rationbook-menubar.png
"

for image in $required_images; do
    path="$repository/docs/screenshots/$image"
    test -s "$path" || {
        echo "Missing README screenshot: docs/screenshots/$image" >&2
        exit 1
    }
    grep -Fq "(docs/screenshots/$image)" "$repository/README.md" || {
        echo "README does not reference docs/screenshots/$image" >&2
        exit 1
    }
done

test -s "$manifest" || {
    echo "Missing README screenshot checksums." >&2
    echo "Capture the current UI, then run scripts/update-readme-screenshot-manifest.sh." >&2
    exit 1
}

for image in $required_images; do
    expected_image=$(awk -F '\t' -v image="$image" '$1 == image { print $2 }' "$manifest")
    actual_image=$(shasum -a 256 "$repository/docs/screenshots/$image" | awk '{print $1}')
    if [ -z "$expected_image" ] || [ "$expected_image" != "$actual_image" ]; then
        echo "README screenshot bytes changed after approval: docs/screenshots/$image" >&2
        exit 1
    fi
done

echo "README screenshot assets and checksums verified"

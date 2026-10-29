#!/bin/sh
# SPDX-License-Identifier: Apache-2.0

set -eu

repository=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository"
"$repository/scripts/check-release-metadata.sh"
"$repository/scripts/check-readme-screenshots.sh"
python3 "$repository/scripts/test-release-directory.py"
"$repository/scripts/test-presentation.sh" --wiring-only
swift test
swift build -c release -Xswiftc -warnings-as-errors
"$repository/scripts/package-app.sh"
plutil -lint "$repository/dist/Rationbook.app/Contents/Info.plist"
test -s "$repository/dist/Rationbook.app/Contents/Resources/Rationbook.icns"
cmp "$repository/LICENSE" "$repository/dist/Rationbook.app/Contents/Resources/LICENSE"
cmp "$repository/NOTICE.md" "$repository/dist/Rationbook.app/Contents/Resources/NOTICE.md"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$repository/dist/Rationbook.app/Contents/Info.plist")" = "Rationbook"
codesign --verify --deep --strict "$repository/dist/Rationbook.app"
echo "Deterministic offline verification passed"

#!/bin/sh
# SPDX-License-Identifier: Apache-2.0

set -eu

repository=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
configuration=${CONFIGURATION:-release}
application="$repository/dist/Rationbook.app"
signing_identity=${RATIONBOOK_CODESIGN_IDENTITY:-}
if [ -z "$signing_identity" ]; then
    signing_identity=$(git -C "$repository" config --local --get rationbook.codesignIdentity 2>/dev/null || true)
fi
if [ -z "$signing_identity" ]; then signing_identity=-; fi

cd "$repository"
"$repository/scripts/check-release-metadata.sh"
swift build -c "$configuration" --product RationbookMenu
swift build -c "$configuration" --product rationbook
swift build -c "$configuration" --product rationbook-claude-helper
build_directory=$(swift build -c "$configuration" --show-bin-path)

python3 "$repository/scripts/release-directory.py" "$repository/dist"
if [ -e "$application" ]; then
    /bin/rm -rf "$application"
fi
mkdir -p "$application/Contents/MacOS" "$application/Contents/Resources/bin"
cp "$repository/Resources/Info.plist" "$application/Contents/Info.plist"
cp "$repository/Resources/Rationbook.icns" "$application/Contents/Resources/Rationbook.icns"
cp "$repository/LICENSE" "$repository/NOTICE.md" "$application/Contents/Resources/"
chmod 644 "$application/Contents/Resources/LICENSE" "$application/Contents/Resources/NOTICE.md"
cp "$build_directory/RationbookMenu" "$application/Contents/MacOS/Rationbook"
cp "$build_directory/rationbook" "$application/Contents/Resources/bin/rationbook"
cp "$build_directory/rationbook-claude-helper" "$application/Contents/Resources/bin/rationbook-claude-helper"
chmod 755 "$application/Contents/MacOS/Rationbook" "$application/Contents/Resources/bin/rationbook" "$application/Contents/Resources/bin/rationbook-claude-helper"
chmod 644 "$application/Contents/Resources/Rationbook.icns"
"$repository/scripts/prepare-release-binary.sh" "$application/Contents/MacOS/Rationbook"
"$repository/scripts/prepare-release-binary.sh" "$application/Contents/Resources/bin/rationbook"
"$repository/scripts/prepare-release-binary.sh" "$application/Contents/Resources/bin/rationbook-claude-helper"

codesign --force --options runtime --sign "$signing_identity" "$application/Contents/Resources/bin/rationbook"
codesign --force --options runtime --sign "$signing_identity" "$application/Contents/Resources/bin/rationbook-claude-helper"
codesign --force --options runtime --sign "$signing_identity" "$application/Contents/MacOS/Rationbook"
codesign --force --options runtime --sign "$signing_identity" "$application"
codesign --verify --deep --strict "$application"
"$repository/scripts/check-public-artifact.sh" "$application"
echo "Signing identity: $signing_identity"
echo "$application"

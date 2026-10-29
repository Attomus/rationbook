#!/bin/sh
# SPDX-License-Identifier: Apache-2.0

set -eu

repository=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
version=$(tr -d '[:space:]' < "$repository/VERSION")
build=$(tr -d '[:space:]' < "$repository/BUILD_NUMBER")
plist_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$repository/Resources/Info.plist")
plist_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$repository/Resources/Info.plist")
swift_version=$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' "$repository/Sources/RationbookCore/Diagnostics.swift")
swift_build=$(sed -n 's/.*static let build = "\([^"]*\)".*/\1/p' "$repository/Sources/RationbookCore/Diagnostics.swift")

case "$version" in ''|*[!0-9A-Za-z.-]*) echo "VERSION contains unsafe characters" >&2; exit 1;; esac
case "$build" in ''|*[!0-9]*) echo "BUILD_NUMBER must be numeric" >&2; exit 1;; esac

if [ "$version" != "$plist_version" ] || [ "$version" != "$swift_version" ]; then
    echo "Version mismatch: VERSION=$version Info.plist=$plist_version Swift=$swift_version" >&2
    exit 1
fi
if [ "$build" != "$plist_build" ] || [ "$build" != "$swift_build" ]; then
    echo "Build mismatch: BUILD_NUMBER=$build Info.plist=$plist_build Swift=$swift_build" >&2
    exit 1
fi

echo "Release metadata: $version ($build)"

#!/bin/sh
# SPDX-License-Identifier: Apache-2.0

set -eu

repository=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
output=${1:-"$repository/docs/screenshots"}
cd "$repository"
swift build --target RationbookCore
build_directory=$(swift build --show-bin-path)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# SwiftPM uses different object layouts with the native and Xcode build systems.
if [ -f "$build_directory/RationbookCore.o" ]; then
    set -- "$build_directory/RationbookCore.o"
    modules="$build_directory"
else
    set -- "$build_directory"/RationbookCore.build/*.o
    modules="$build_directory/Modules"
fi

# Compile the real UI with a synthetic model; no provider service is created.
swiftc -parse-as-library -I "$modules" -I "$repository/Sources/CSQLite" \
    "$repository"/Sources/RationbookApp/*.swift "$repository/scripts/render-screenshots.swift" \
    "$@" -lsqlite3 -o "$work/Capture"
"$work/Capture" "$output"

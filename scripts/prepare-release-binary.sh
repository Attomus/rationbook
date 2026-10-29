#!/bin/sh
# SPDX-License-Identifier: Apache-2.0

set -eu

if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
    echo "Usage: scripts/prepare-release-binary.sh MACH_O_EXECUTABLE" >&2
    exit 64
fi
binary=$1

# Current release executables use system libraries only. Refuse new dependencies
# before removing toolchain search paths; a future bundled library needs review.
dependencies=$(/usr/bin/otool -L "$binary")
if ! printf '%s\n' "$dependencies" | /usr/bin/awk '
    NR == 1 { next }
    $1 !~ /^\/usr\/lib\// && $1 !~ /^\/System\/Library\// { exit 1 }
'; then
    echo "Release executable has a non-system library dependency" >&2
    exit 65
fi

# Swift Build can add absolute toolchain rpaths independently of swiftc flags.
# Retain system/bundle-relative paths and reject anything outside that contract.
load_commands=$(/usr/bin/otool -l "$binary")
rpaths=$(printf '%s\n' "$load_commands" | /usr/bin/awk '
    $1 == "cmd" && $2 == "LC_RPATH" { rpath = 1; next }
    rpath && $1 == "path" {
        sub(/^[[:space:]]*path /, ""); sub(/ \(offset [0-9]+\)$/, "")
        print; rpath = 0
    }
')
printf '%s\n' "$rpaths" | while IFS= read -r path; do
    case "$path" in
        ''|/usr/lib/swift|'@loader_path'|'@executable_path/../Frameworks') ;;
        /*.xctoolchain/usr/lib/swift/*|/*.xctoolchain/usr/lib/swift-*/macosx)
            /usr/bin/install_name_tool -delete_rpath "$path" "$binary"
            ;;
        *) echo "Unexpected release runtime search path" >&2; exit 65 ;;
    esac
done
/usr/bin/strip -S "$binary"

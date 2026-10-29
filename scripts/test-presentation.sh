#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
set -eu
repository=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# Settings and the panel must not bypass current-reading presentation with raw
# provider state (which intentionally includes retained historical diagnostics).
if grep -En '(provider|[$]0)[.]state' \
    "$repository/Sources/RationbookApp/RationbookSettings.swift" \
    "$repository/Sources/RationbookApp/RationbookPopover.swift"; then
    echo "UI badges must use HumanPresentation, not raw provider state." >&2
    exit 1
fi
[ "${1:-}" != "--wiring-only" ] || exit 0
# Compile the production presentation model and its normal Swift tests on Linux,
# without the macOS process, Keychain and UI targets.
workspace=$(mktemp -d)
trap 'rm -rf "$workspace"' EXIT
mkdir -p "$workspace/Sources/RationbookCore" "$workspace/Tests/RationbookCoreTests"
cp "$repository/Sources/RationbookCore/Models.swift" "$workspace/Sources/RationbookCore/"
cp "$repository/Tests/RationbookCoreTests/PresentationTests.swift" "$workspace/Tests/RationbookCoreTests/"
cat > "$workspace/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "PresentationChecks", targets: [
    .target(name: "RationbookCore"),
    .testTarget(name: "RationbookCoreTests", dependencies: ["RationbookCore"])
])
PACKAGE
swift test --package-path "$workspace"

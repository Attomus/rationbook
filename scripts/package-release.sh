#!/bin/sh
# SPDX-License-Identifier: Apache-2.0

set -eu

repository=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
identity=${DEVELOPER_ID_APPLICATION:-}
notary_profile=${NOTARYTOOL_PROFILE:-}

if [ -z "$identity" ] || [ -z "$notary_profile" ]; then
    echo "Set DEVELOPER_ID_APPLICATION and NOTARYTOOL_PROFILE before creating a notarized release." >&2
    exit 64
fi

if [ "$(git -C "$repository" rev-parse --show-toplevel 2>/dev/null)" != "$repository" ] ||
    ! git -C "$repository" rev-parse --verify HEAD >/dev/null 2>&1; then
    echo "Release packaging requires a committed public source checkout." >&2
    exit 65
fi
if [ "$(uname -m)" != arm64 ]; then
    echo "This release supports Apple Silicon only." >&2
    exit 65
fi
if [ -n "$(git -C "$repository" status --porcelain --untracked-files=all)" ]; then
    echo "Release packaging requires a clean working tree." >&2
    exit 65
fi

# Build and sign only a fresh tracked-source snapshot in a private workspace.
# Git cleanliness alone does not authenticate ignored build/output directories.
python3 "$repository/scripts/release-directory.py" "$repository/dist"
temporary_root=$(getconf DARWIN_USER_TEMP_DIR)
python3 "$repository/scripts/release-directory.py" "$temporary_root"
python3 - "$temporary_root" <<'PYFREE'
import os
import sys
volume = os.statvfs(sys.argv[1])
free = volume.f_bavail * volume.f_frsize
if free < 11 * 1024 ** 3:
    sys.exit(f"Release needs a 10 GiB free floor plus 1 GiB build reservation; available: {free} bytes")
PYFREE
release_workspace=$(mktemp -d "${temporary_root%/}/rationbook-release.XXXXXXXX")
trap '/bin/rm -rf "$release_workspace"' EXIT
source_repository=$repository
git -C "$source_repository" archive HEAD > "$release_workspace/source.tar"
mkdir "$release_workspace/source"
tar -xf "$release_workspace/source.tar" -C "$release_workspace/source"
repository="$release_workspace/source"
"$repository/scripts/check-release-metadata.sh"
"$repository/scripts/test-presentation.sh" --wiring-only
swift test --package-path "$repository"
CONFIGURATION=release "$repository/scripts/package-app.sh"

application="$repository/dist/Rationbook.app"
version=$(tr -d '[:space:]' < "$repository/VERSION")
archive="$repository/dist/Rationbook-$version.zip"
checksum="$archive.sha256"

codesign --force --options runtime --timestamp --sign "$identity" "$application/Contents/Resources/bin/rationbook"
codesign --force --options runtime --timestamp --sign "$identity" "$application/Contents/Resources/bin/rationbook-claude-helper"
codesign --force --options runtime --timestamp --sign "$identity" "$application/Contents/MacOS/Rationbook"
codesign --force --options runtime --timestamp --sign "$identity" "$application"
codesign --verify --deep --strict --verbose=2 "$application"

if [ -e "$archive" ]; then /bin/rm -f "$archive"; fi
ditto -c -k --sequesterRsrc --keepParent "$application" "$archive"
"$repository/scripts/check-public-artifact.sh" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$application"
xcrun stapler validate "$application"

/bin/rm -f "$archive" "$checksum"
ditto -c -k --sequesterRsrc --keepParent "$application" "$archive"
"$repository/scripts/check-public-artifact.sh" "$archive"

verification_directory="$release_workspace/verification"
mkdir "$verification_directory"
ditto -x -k "$archive" "$verification_directory"
codesign --verify --deep --strict --verbose=2 "$verification_directory/Rationbook.app"
spctl --assess --type execute --verbose=2 "$verification_directory/Rationbook.app"

(cd "$repository/dist" && shasum -a 256 "Rationbook-$version.zip" > "Rationbook-$version.zip.sha256")
if grep -q '/' "$checksum"; then
    echo "Checksum sidecar unexpectedly contains a path." >&2
    exit 66
fi
echo "$archive"
echo "$checksum"

digest=$(awk '{print $1}' "$checksum")
cat > "$repository/dist/rationbook.rb" <<EOF
cask "rationbook" do
  version "$version"
  sha256 "$digest"

  url "https://github.com/attomus/rationbook/releases/download/v#{version}/Rationbook-#{version}.zip"
  name "Rationbook"
  desc "Local Codex and Claude capacity monitor"
  homepage "https://github.com/attomus/rationbook"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Rationbook.app"

  caveats <<~EOS
    Before removing Rationbook, remove its optional Claude feed and CLI
    using the app or rationbook uninstall.
  EOS
end
EOF
echo "$repository/dist/rationbook.rb"

python3 "$repository/scripts/release-directory.py" "$source_repository/dist"
mkdir -p "$source_repository/dist"
for name in "Rationbook-$version.zip" "Rationbook-$version.zip.sha256" rationbook.rb; do
    # Refuse pre-existing symlink targets rather than following them during copy.
    if [ -L "$source_repository/dist/$name" ]; then
        echo "Refusing a symlinked release output." >&2
        exit 65
    fi
    staged_output=$(mktemp "$source_repository/dist/.release.XXXXXXXX")
    cp "$repository/dist/$name" "$staged_output"
    mv -f "$staged_output" "$source_repository/dist/$name"
done
echo "Release archive: $source_repository/dist/Rationbook-$version.zip"

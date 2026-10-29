# Releasing Rationbook

Each release must match a reviewed commit in `attomus/rationbook`. Distribute an Attomus Limited Developer ID-signed, Apple-notarised ZIP for Apple Silicon/macOS 14+, with a SHA-256 sidecar. Homebrew uses the same archive; source builds use development signatures.

Run all macOS builds, tests, linting, packaging and signing locally or in Xcode Cloud. GitHub Actions runs Linux source and presentation regression checks only. Record the commit, macOS version, architecture, toolchain and results.

## Candidate checks

Install ShellCheck and SwiftLint, then run:

```sh
shellcheck scripts/*.sh
swiftlint lint --strict
scripts/test-public-source-tools.sh
scripts/verify.sh
```

These offline checks cover scripts, metadata, images, tests, compilation, packaging, licence notices and signatures. The same presentation tests run in Linux CI and the full macOS suite: current readings with retained history, stale or missing readings, refresh failures, and sign-in requirements. A wiring check rejects raw provider-state badges in Settings and the panel. `package-release.sh` runs these checks and the full Swift suite against its clean source snapshot before signing; a failed test stops packaging. Exit codes determine success. Provider commissioning is separate; opt in on the exact candidate:

```sh
RATIONBOOK_ALLOW_LIVE_PROVIDER_SMOKE=1 scripts/live-provider-smoke.sh
```

Record provider versions and fresh/idle behaviour. Never publish credentials or account data in evidence or CI artefacts.

## Identity and signing

Update `VERSION`, `BUILD_NUMBER`, `Resources/Info.plist`, `RationbookBuild` and `CHANGELOG.md` together; check with `scripts/check-release-metadata.sh`. Bundle identifier and preferences prefix: `org.attomus.rationbook`.

For stable development signing:

```sh
git config --local rationbook.codesignIdentity "CERTIFICATE_SHA1"
```

`package-app.sh` prefers `RATIONBOOK_CODESIGN_IDENTITY`, then this local setting, then ad-hoc signing. Keep personal certificate details out of source. `package-app.sh` is a development packaging command and reuses compiler state; distributable Developer ID releases must use `package-release.sh`.

Import the Developer ID Application certificate into the login Keychain. Store notarisation credentials there, never in the repository:

```sh
xcrun notarytool store-credentials RationbookNotary \
  --apple-id "APPLE_ID" --team-id "TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"
```

After human review on a Mac:

```sh
export DEVELOPER_ID_APPLICATION="Developer ID Application: OWNER (TEAM_ID)"
export NOTARYTOOL_PROFILE="RationbookNotary"
scripts/package-release.sh
```

The script requires a clean committed checkout and builds a fresh tracked-source snapshot in a private temporary directory, without reusing ignored build state. It checks output-directory ownership, modes and ACLs, and refuses symlinked output directories. The temporary build workspace is removed on exit. It signs executables and app with hardened runtime, submits the ZIP, staples and validates acceptance, recreates and extracts the final archive, verifies signatures/Gatekeeper and writes a basename-only checksum under `dist/`.

## Publication checks

- Confirm exact-commit deterministic checks and Linux CI pass.
- On the candidate, compare Settings badges with the main panel for current readings, retained history and a failed refresh. Sign-out must give an actionable sign-in instruction, and successful sign-in must restore fresh readings.
- Switch Essential/Full and expand history: the popover must stay anchored, fit the display and scroll without transparent gaps. These native layout checks are manual; model tests do not establish rendered UI correctness.
- Enable private vulnerability reporting and verify its contact link.
- Download the intended archive on a separate Mac; verify Gatekeeper without bypass instructions, VoiceOver and logout/login behaviour.
- Run the opt-in live-provider check manually for any live-integration release claim.
- Compare the signed app with the README gallery; regenerate affected screenshots with synthetic data.
- Check licence, notices, copyright, privacy/security policies and changelog.
- Tag and publish only when downloaded artefact and checksum match the tested files.

Updates are manual and should link to the changelog. Never instruct users to bypass Gatekeeper.

## Homebrew and other distribution

Packaging also generates `dist/rationbook.rb`. Upload the tested ZIP and sidecar, then update `Casks/rationbook.rb` and `Formula/rationbook.rb` in `Attomus/homebrew-tap` with the same version, URL and SHA-256. The formula installs the signed CLI/helper; the cask installs the app. Verify against the hosted download and test installation, upgrade and removal before advertising either. The generated cask neither publishes itself nor enables integrations or deletes data.

The Mac App Store is not a target: integrations outside App Sandbox would need a separately reviewed design.

# Contributing

Rationbook optimises for a small, auditable provider surface and does not own provider credentials. New integrations should use documented local interfaces or a stable, explicitly permitted API with authentication retained by the provider's own tool. Consumer OAuth reuse, private browser automation, transcript collection, and a permanent daemon remain out of scope.

Use the repository templates for bugs, focused feature proposals, and pull requests. Report suspected vulnerabilities privately as described in [`SECURITY.md`](SECURITY.md), never in a public issue.

Run `scripts/verify.sh` before opening a pull request. Add synthetic contract fixtures for every provider-field change; never commit real account identifiers, quota payloads, credentials, prompts, transcripts, or local paths.

UI changes must replace and review the complete README screenshot set, then update its manifest as described in `docs/screenshots/README.md`. Changes to the app icon should update `scripts/generate-app-icon.swift` and regenerate `Resources/Rationbook.icns`; do not edit only the binary asset.

Run `scripts/check-release-metadata.sh` after version changes. Update `VERSION`, `BUILD_NUMBER`, `Resources/Info.plist`, `RationbookBuild`, and `CHANGELOG.md` together.

Changes to the versioned JSON contract need a compatibility note. Additive enum cases are not automatically safe because consumers may exhaustively switch over them.

Contributions to the public repository are reviewed by Attomus Labs and accepted under Apache-2.0. Include only code and assets you have the right to contribute.

`scripts/test-presentation.sh` runs the portable status regression suite on Linux or macOS using the production model. Use `HumanPresentation` for current-reading badges; raw provider state includes historical diagnostics. The full macOS suite remains required for releases.

# Release security review

Security review performed 26 October 2026 · Attomus Labs

Rationbook runs locally and launches provider tools with the user's permissions. Protecting those boundaries is part of making it useful software, including as an open-source release.

Release preparation included a source security review under OpenAI's Daybreak programme, with maintainer validation, and a separate Codex Security review of the same source candidate. Findings were assessed against the implementation and checked with targeted regression tests. The scope covered the app, CLI, Claude helper, storage, parsers and release scripts.

## Areas addressed

| Area | Change |
| --- | --- |
| Provider executable permissions | Include macOS extended ACLs when checking executable paths and their ancestors. |
| Private storage and helper paths | Validate each newly created directory component before descending, including nested custom data locations. |
| Claude settings | Reject replaceable ancestors and mutation-granting ACLs before installation, recovery or restoration. |
| Optional CLI installation | Check destination directories before installation, recovery and removal. |
| Quota input | Reject invalid numeric types, extreme values and duplicate identities before storage; preserve legitimate overage and the last valid snapshot. |
| Release packaging | Build from a fresh tracked-source snapshot in private staging, and validate output paths before copying signed artefacts. |

The filesystem findings require another local principal to have mutation rights over relevant paths; they do not establish remote unauthenticated access. The release-workspace finding depended on attacker-influenced build/output state and was treated as a hardening requirement. Parser findings concerned quota integrity and availability.

## Verification and limits

The combined changes passed local regression tests covering ACL grants, replaceable ancestors, CLI destination safety, provider fallback, malformed quota inputs and preservation of valid history. The full Swift test suite, warnings-as-errors release build, script linting, source-export checks and development-package validation passed. A focused Daybreak patch review identified two additional edge cases; both were corrected and covered by regressions. Distribution signing and Apple notarisation are recorded separately for the delivered archive.

Source review and regression checks reduce risk; they do not prove that no other vulnerabilities exist. Use of these tools is neither certification nor endorsement by OpenAI. These reviews did not test provider accounts or services, and did not constitute a penetration test. Reports should be made privately using [SECURITY.md](../SECURITY.md).

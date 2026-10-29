# Security verification

This document describes the checks applied to each release. It is not a security certification.

The automated suite covers executable identity and path ownership, bounded child processes and cleanup, private SQLite storage, integration install and recovery, quota parsing and reduced diagnostics. Export checks enforce the source allowlist and scan release artefacts for excluded material. Release builds are additionally reviewed, signed and notarised on a Mac, as set out in [RELEASING.md](RELEASING.md).

The trust boundaries are described in [SECURITY.md](../SECURITY.md) and the data inventory in [PRIVACY.md](../PRIVACY.md). Please report suspected vulnerabilities privately through the process in [SECURITY.md](../SECURITY.md).

See the [release security review](RELEASE_SECURITY.md) for the scope, findings and verification recorded during release preparation.

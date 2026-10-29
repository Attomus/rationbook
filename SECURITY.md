# Security policy

Report suspected vulnerabilities through this repository’s private vulnerability-reporting flow. Exclude credentials, cookies, prompts, transcripts and unredacted databases. Security updates target the latest release on `main`.

## Process boundary

Rationbook runs outside the App Sandbox to discover user-installed provider tools and manage the opted-in Claude helper. It checks resolved executable paths, ownership, permission bits and extended ACLs throughout the directory chain. Mutation-granting ACLs are refused; read-only and deny entries are permitted. Foreign-owned and world-writable paths, and group-writable executable files, are rejected. Group-writable ancestors are accepted only with the expected Apple-anchored OpenAI or Anthropic Developer ID and code identifier, as in supported Homebrew layouts.

For accepted group-writable installation ancestors, the validated inode is hard-linked into a unique launch directory under macOS’s kernel-reported, current-user-owned `0700` temporary directory, revalidated and launched there. Unsafe temporary-directory ownership or permissions stop the launch. This prevents replacement of the original directory entry from changing the executable. Arguments are passed separately, output is bounded and drained, and timeouts escalate to forced process-group termination. Pipe endpoints are close-on-exec; children are reaped by their lifecycle caller.

Rationbook does not implement OAuth, inspect credential stores or call undocumented consumer-usage endpoints. Provider authentication stays with the provider tools. Integration and contractual details are in [PROVIDERS.md](docs/PROVIDERS.md).

## Integration boundary

The Claude helper forwards original input to an existing status-line command only after checking its installed path, digest, bound root and current-format manifest. A closed forwarding pipe cannot terminate quota persistence. Uninstallation restores the previous status-line value only if the installed wrapper still matches the recorded value. CLI/helper records are confined to owned paths; digests are checked before replacement or removal. Settings symlinks, replaceable ancestor directories and mutation-granting ACLs are refused.

`CapacitySource` accepts bounded quota snapshots, validated before policy or storage, with no credential, endpoint, raw-response or account-identity fields. The optional stdin supplement is limited to 64 KiB and eight model windows, rejects unknown fields and does not launch or authenticate its source.

`RATIONBOOK_DATA_DIR` must be absolute, private and current-user-owned. Symlinked or unsafe roots/files, replaceable ancestor directories and writes outside the bound root are rejected. Missing directories are created and validated one component at a time before descendants are created. Root-owned sticky temporary directories are supported when the descendant chain is protected. The optional CLI destination receives the same ancestor and ACL checks. Local storage, diagnostics, notifications and deletion are documented in [PRIVACY.md](PRIVACY.md). Open at Login is opt-in; no privileged helper is installed.

See [security verification](docs/SECURITY_REVIEW.md) for release checks and their limits.

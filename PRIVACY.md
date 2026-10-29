# Privacy

Rationbook has no account service, advertising, analytics, telemetry, backend or remote crash reporting. It does not request, read, proxy or store provider credentials.

## Inputs and storage

Rationbook reads Codex aggregate quota responses, Claude’s optional status-line feed, local settings, executable versions and login-item status. An optional supplement supplies model names, percentages, observation/reset times, labels and durations.

The helper processes complete status-line events transiently and forwards their original bytes to an existing command. It stores only aggregate quota, Claude version and one-way hashes of session/API-duration markers for replay detection. It does not retain prompts, responses, transcripts, raw session IDs, repository identity, working directories, model data from that event, cookies or credentials.

`~/Library/Application Support/Rationbook/` contains:

- Normalised quota state, SQLite history and integration ownership records.
- The Claude observation and optional model-capacity supplement.
- The copied CLI/helper, `Refresh Claude.command` launcher and `claude-session-*.json` replay records.

Each replay record holds one session’s quota observation and remains until support-data removal. The launcher contains paths and process settings, not credentials. The directory is user-only; history retention is configurable. App preferences live in the macOS preferences domain. `RATIONBOOK_DATA_DIR` can relocate storage for tests or advanced use, subject to the [path restrictions](SECURITY.md).

## Processes and disclosure

Rationbook makes no provider HTTPS requests itself. Provider CLIs own authentication and network access. Claude refresh discards terminal output and disables session/prompt-history persistence for its own session. Provider tools may maintain their own diagnostic logs; Rationbook does not remove them. Refresh settings and fallback are described in [PROVIDERS.md](docs/PROVIDERS.md).

Copied diagnostics contain app/system versions and fixed health facts, excluding provider paths/free text, quota, identity, prompts, transcripts and credentials. Copying places the report on the clipboard without transmitting it. Optional notifications give macOS a provider/window label and, for reserve events, the remaining percentage. macOS controls notification storage and display. Open at Login is off until enabled by the user.

## Removal

1. Disable Open at Login.
2. Run `rationbook uninstall` to remove owned CLI and Claude integrations.
3. Quit and delete `~/Library/Application Support/Rationbook/` to remove history and records.
4. Optionally run `defaults delete org.attomus.rationbook` to remove preferences.

Remove integrations before deleting the app or support data. Deleting the app alone leaves both integrations and history. Rationbook has no automatic updater.

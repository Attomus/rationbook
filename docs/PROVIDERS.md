# Provider behaviour

## Codex

Rationbook starts `codex app-server` over stdio, sends JSONL `initialize`, `initialized` and `account/rateLimits/read`, then closes the process. It prefers `rateLimitsByLimitId`, falling back to `rateLimits` only when the map is absent. IDs combine the provider limit ID, window position and duration; labels never determine semantics. This app-server surface is experimental.

The app refreshes Codex on open when observations exceed 30 seconds and at most once per five minutes in the background. Ordinary CLI reads are cache-first; without cached state they may run `--version` for installation detection, but require `--refresh` to acquire quota.

## Claude setup

Enable the feed in Settings or run `rationbook claude install-feed`. Installation copies the helper, records the previous `statusLine` object and installs a command bound to Rationbook’s data root. Existing status-line input is forwarded unchanged. Claude settings are re-serialised with sorted keys and unescaped slashes; unrelated values are preserved. Symlinked settings files are refused by design. There is no whole-file backup.

The feed consumes Claude Code’s documented [status-line JSON](https://code.claude.com/docs/en/statusline). It provides aggregate quota, not model-specific allowances. Missing limits mean unknown capacity, not zero. Empty events retain useful readings. Identical session/API-duration markers do not advance timestamps; hashed per-session records prevent alternating replays from replacing newer readings. A new marker is a local observation, not proof of a new upstream request; Claude supplies no upstream observation timestamp.

## Refresh and tokens

**Refresh Claude** starts the installed, unmodified Claude Code in stream-JSON mode and sends only a `get_usage` control request. It reads shared limits and model-specific weekly allowances returned in `model_scoped` or known `seven_day_<family>` fields. Model usage is an allowance percentage, not a count of tokens or completed jobs. Runway is estimated from successive readings; a first reading alone cannot establish a rate.

Rationbook sends no user message or model prompt. Claude Code performs the network request using its own authentication. Rationbook does not read OAuth tokens, Keychain credentials or browser cookies. This follows the authentication boundary described in Anthropic’s [product and credential guidance](https://code.claude.com/docs/en/legal-and-compliance); Attomus has accepted the Commercial Terms. It is not an Anthropic endorsement. `get_usage` is a version-dependent CLI control interface, not a documented stable public API; unsupported replies fail without replacing stored readings. The structured path was checked with Claude Code 2.1.330 and 2.1.332.

Refresh disables hooks, tools, Fast mode and session persistence through process-local options. It uses the individual telemetry, error-reporting and updater opt-outs rather than the broad nonessential-traffic switch, which can also block quota reads in newer Claude Code versions. An inherited `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` setting is still honoured and can prevent refresh. It does not change saved Claude settings or parse terminal output. An absent window means no current observation, not zero usage or unlimited capacity. The status-line helper remains available for passive aggregate updates; those events do not refresh the timestamp of model-specific readings.

In Settings, choose **Manual, 5, 15, 30 or 60 minutes**; the default is 15 minutes. While running and awake, the app checks once a minute, plus on open/wake. It refreshes when the selected interval has elapsed since the last attempt. Passive account updates do not postpone model-specific refreshes. Attempts cannot overlap and are limited to 40 seconds plus cleanup. Failures retain last-known values and retry on the selected schedule. Manual stops automatic launches, including open/wake, but keeps the normal feed and **Refresh Claude** available. Changing the interval does not cancel a refresh already running. Quitting stops the schedule; sleep pauses it.

For sign-in or unexpected CLI states, choose **Open Claude in Terminal…** or run `rationbook claude refresh`. Check that `/usage` shows your subscription’s five-hour and weekly percentages, then press Esc to emit the status line. Rationbook confirms when it receives a new reading; opening Terminal alone is not confirmation. If that Claude installation reports signed out, the app offers **Sign in to Claude…**, which opens Claude’s sign-in flow. Complete sign-in, then enter `/usage` and press Esc after the percentages appear. You can then use `/exit` to close the session. After signing in, choose **Refresh Claude** to fetch model-specific limits as well. Opening the Terminal path also updates an already-enabled feed helper to the bundled version. `rationbook claude refresh --automatic` runs the bounded path explicitly. Neither path is launched by ordinary CLI status reads.

## Authentication and terms

Rationbook follows Anthropic’s [authentication and credential-use guidance](https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use). Each user runs their own unmodified Claude Code and authenticates through Anthropic’s flow. Rationbook does not offer Claude login, extract tokens, proxy inference or resell access. It neither bundles Claude Code nor represents affiliation or endorsement.

Anthropic’s terms apply to Claude Code; Apache-2.0 does not replace them. Running Claude Code in a product requires agreement to Anthropic’s [Commercial Terms](https://www.anthropic.com/legal/commercial-terms), or an applicable agreement. Distributors must meet that requirement.

## Compatibility and removal

Prefer native vendor installers or Homebrew. Installations under nvm, fnm, volta, mise or bun are not categorically rejected, but unsafe executable or ancestor permissions are; see [SECURITY.md](../SECURITY.md). A vendor signature can permit the supported group-writable Homebrew layout.

Remove the feed before deleting support data: `rationbook claude uninstall-feed`. If settings changed, removal stops without overwriting them. Compare the current status line with the recorded prior object in `claude-integration.json`.

An authorised external source can supply model-scoped observations through `supplement import`; the [API contract](API.md) defines validation. Rationbook does not launch or authenticate that source.

Freshness is a product policy, not a provider promise: Codex is fresh through two minutes, ageing through 15; Claude is fresh through ten, ageing through 60. Later readings are stale. A longer refresh interval does not extend these thresholds. See [PRIVACY.md](../PRIVACY.md) for storage and removal.

Quota ingestion rejects booleans, non-finite numbers, duplicate window identifiers and excessive text. Usage above 100% remains visible; values above 10,000% are rejected as corrupt. Reset timestamps must fall between the Unix epoch and year 9999. A rejected refresh does not overwrite the last valid stored snapshot.

Claude reset dates come from its quota feed. The weekly schedule is separate from subscription billing; renewing does not necessarily move the reset seven days ahead. See [Anthropic’s Max plan guidance](https://support.claude.com/en/articles/11049741-what-is-the-max-plan).

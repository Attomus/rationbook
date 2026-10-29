# CLI JSON contract

Rationbook 0.1.1 exposes schema version 1 through the packaged `rationbook` executable. Commands with `--json` write exactly one JSON value to stdout. Keys are `snake_case`, dates are ISO 8601 strings, and optional values are omitted when unavailable. Human-readable errors go to stderr.

## Commands and refresh semantics

| Command | JSON result | Provider access |
| --- | --- | --- |
| `status --json` | `StatusEnvelope` | Cache-first; when a provider has no cached state, may run its local executable with `--version` to report installation support |
| `status --refresh --json` | `StatusEnvelope` | Attempts a bounded provider refresh, then returns the best normalised state available |
| `forecast --json` | `ForecastEnvelope` | Cache-first; may perform the same local installation detection when no provider cache exists |
| `forecast --refresh --json` | `ForecastEnvelope` | Same explicit refresh behaviour as status |
| `history --json --limit N` | `HistoryEnvelope` | Local SQLite only; default limit is 100 |
| `claude refresh` | Interactive terminal only; no JSON | Opens unmodified Claude Code `/usage`; the installed local feed receives quota |
| `doctor --json` | `DoctorReport` | Local installation and state checks |
| `diagnostics --json` | `RationbookDiagnosticReport` | Privacy-reduced form of doctor plus app/system version |
| `supplement status --json` | `ModelCapacitySupplement` or `null` | Local quota-only supplement file |

Status includes hidden windows; forecasts include account windows only. Default reads never acquire quota, but may check installation with `--version`. Codex needs `--refresh`; Claude needs an installed feed and a separate `claude refresh` or `claude refresh --automatic`. See [PROVIDERS.md](PROVIDERS.md).

Exit codes are `0` for a valid command result, `64` for invalid usage, and `70` for an internal failure. `status` returns `2` after writing its valid result when no provider state is usable. A forecast with no actionable scenario remains a valid result with an `unavailable_reason`, so it returns `0`.

## Status schema

`StatusEnvelope` contains:

| Field | Type |
| --- | --- |
| `schema_version` | Integer; currently `1` |
| `generated_at` | ISO 8601 date |
| `overall_state` | `available`, `partial`, or `unavailable` |
| `providers` | Array of `ProviderStatus` |
| `errors` | Array of `StructuredError` |

Each `ProviderStatus` contains `provider`, `agent_label`, `state`, `capabilities`, `source`, `windows`, and `errors`. It may also contain `account`, `planning_state`, `limiting_window_id`, and `model_specific_capacity`.

- `provider` is the stable provider identifier (`openai` or `anthropic`); `agent_label` is the human product label.
- `state` is `available`, `partial`, `stale`, `unavailable`, `missing`, `logged_out`, `unsupported`, or `waiting_for_observation`.
- `account`, when present, contains an optional `plan`.
- `capabilities` contains the booleans `supports_on_demand_refresh`, `supports_push_updates`, `supports_account_scope`, and `supports_model_scope`.
- `source` contains `name`, `documentation`, `maturity`, `authentication`, and optional `tested_tool_version` provenance.
- `planning_state` is `available`, `exhausted`, `uncertain`, or `unavailable`.
- `limiting_window_id` identifies the reserve-adjusted account window currently constraining planning.

Each quota window contains these base fields:

| Field | Meaning |
| --- | --- |
| `id` | Stable normalised window identifier |
| `provider_id`, `provider_label` | Optional upstream identity and label |
| `display_label` | Human label such as `5 hour` or `7 day` |
| `scope` | `account` or an explicitly supplied narrower scope such as `model` |
| `model` | Optional provider-supplied model identifier |
| `duration_seconds` | Optional nominal window duration |
| `observed_at` | Time of the underlying observation |
| `freshness` | `fresh`, `aging`, `stale`, or `unknown` |
| `used_percent`, `remaining_percent` | Raw percentage values normalised to the same capacity basis |
| `expected_resets_at`, `reset_observed_at` | Optional scheduled and observed reset evidence |
| `data_quality` | `authoritative`, `local_observed`, or `inferred` |

Provider percentages are preserved rather than silently clamped, so consumers must tolerate transient values outside 0–100. The interface may clamp only its drawing geometry.

A window may additionally contain:

- `policy`: `reserve_percent`, `safe_remaining_percent`, and policy `state`;
- `observed_rate`: `net_change_pp_per_wall_hour`, non-negative `forecast_burn_pp_per_wall_hour`, `confidence`, `sample_count`, and `interval_started_at`;
- `reserve_scenario`: `hours_until_reserve`, optional `hours_until_expected_reset`, `first_event` (`expected_reset` or `reserve`), and `confidence`; or
- `forecast_unavailable_reason` when Rationbook refuses to produce a scenario.

Rate fields use percentage points per wall-clock hour. UI labels shorten this to `%/h`, but the JSON names retain the dimensionally explicit `pp_per_wall_hour`. Estimate confidence is `high`, `medium`, `low`, or `unavailable`.

`StructuredError` contains a stable machine `code` and a sanitised human `message`. Treat the code as the contract; messages may improve between releases.

## Local model-capacity supplement

`rationbook supplement import` validates stdin JSON and stores only supported fields with user-only permissions. Limits: 64 KiB and eight Anthropic model windows:

```json
{
  "schema_version": 1,
  "provider": "anthropic",
  "observed_at": "2026-09-03T22:44:36Z",
  "windows": [{
    "model": "Fable",
    "display_label": "Fable weekly",
    "duration_seconds": 604800,
    "used_percent": 22,
    "resets_at": "2026-09-04T18:59:59Z"
  }]
}
```

Unknown fields, unsupported providers, duplicate/invalid windows, control characters, non-finite or out-of-range percentages, implausible times, and oversized input are rejected. The schema has no credential, endpoint, account-identity, arbitrary metadata, or command field. Imported windows have `scope: model` and `data_quality: local_observed`; normal freshness and reserve policies apply. The data source remains outside Rationbook and is responsible for having authority to obtain the observation.

## Forecast, history, and diagnostics

`ForecastEnvelope` contains `schema_version`, `generated_at`, and `windows`. Each forecast window contains `provider`, `window_id`, `display_label`, `freshness`, and either a `scenario` in the form above or an `unavailable_reason`. Forecast includes account-scope windows only.

`HistoryEnvelope` contains `schema_version`, `generated_at`, and `samples`. Each sample contains `provider`, `window_id`, `used_percent`, `remaining_percent`, optional `expected_resets_at`, `first_observed_at`, `last_observed_at`, `sample_count`, and `freshness`. A sample may coalesce repeated static observations; `sample_count` records how many observations it represents.

`DoctorReport` contains `schema_version`, `generated_at`, and `checks`; each check has `name`, `status`, and `detail`. `RationbookDiagnosticReport` adds `app_version`, `app_build`, `operating_system`, and `architecture` while replacing doctor content with fixed, privacy-reduced facts. Diagnostics deliberately exclude provider paths/version strings, quota values, account identity, prompts, transcripts, and credentials.

## Compatibility policy

Consumers must reject an unsupported `schema_version`, tolerate unknown object fields, and avoid exhaustive switching on enums without an unknown fallback. Additive object fields are intended to remain compatible inside schema 1; removing or changing a field's meaning requires a schema-version change. Presentation settings never remove data from these contracts.

## Invalidated observations

Quota windows may include `invalidation_reason`. `quota_window_absent_after_reset` means the provider stopped reporting that window after its expected reset. The last reading remains stale and unsuitable for planning until a new source observation restores it, regardless of its age. The forecast reports the same cause through `unavailable_reason`. Missing this optional field remains compatible with existing schema-version-1 consumers.

## Library extensions

`RationbookCore.CapacitySource` accepts explicitly supplied quota snapshots; `RationbookUI` exposes the menu presentation and configuration. Neither discovers implementations at runtime. See [ARCHITECTURE.md](ARCHITECTURE.md) for extension responsibilities.

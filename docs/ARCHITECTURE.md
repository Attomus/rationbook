# Architecture

```text
Codex CLI app-server ── stdio JSONL ── CodexAdapter ─┐
Claude Code statusLine ─ local helper ─ ClaudeAdapter ├─ RationbookCore ─ SQLite WAL
Local quota supplement ─ strict stdin ───────────────┘       │
                                                            ├─ menu-bar app
                                                            └─ CLI/JSON
```

The app and CLI are peers over a local support directory; there is no resident service. Provider payloads stop inside their adapters. `ProviderStatus` and `QuotaWindow` form the shared contract.

`RationbookService` applies freshness, reserves, reset reconciliation, history lookup and forecasts. `SQLiteStore` owns migrations, WAL, latest-provider cache, coalesced observations and retention. Integration managers own only the files recorded in their manifests and recover interrupted installation. `RationbookDiagnostics` produces the reduced support report. Open at Login uses `SMAppService.mainApp`, without a daemon or XPC service.

## Refresh and failure

The app’s existing background task checks refresh eligibility, alongside panel-open and wake events. `ClaudeRefreshInterval` applies the selected schedule to both the last attempt and observation times; the attempt timestamp survives app restarts. Manual selection suppresses scheduled launches, while explicit refresh remains available. Sessions cannot overlap. Quitting stops the schedule; sleep pauses it.

A bounded terminal driver starts Claude Code’s built-in usage command, consumes the helper’s quota feed and terminates its process group. Terminal output is discarded. Authentication or unexpected states use the interactive fallback. A lock collision returns cached data with `refresh_in_progress`. One provider’s failure does not terminate the other; last-good observations remain available. Timing and provider compatibility are defined in [PROVIDERS.md](PROVIDERS.md), and process controls in [SECURITY.md](../SECURITY.md).

## History and estimates

Static observations are normalised to three decimal places and coalesced. Re-reading the same Claude event does not inflate sample counts. Reset evidence is reconciled against provider schedules; a counter decrease alone does not prove a reset. Windows missing after an expected reset retain durable invalidation until reported again.

Burn rate uses the newest continuous segment within six hours, splits on gaps over two hours or decreases over two percentage points, and requires three samples spanning 15 minutes. Only medium/high-confidence, non-stale, positive rates produce a scenario.

## Extension points

`CapacitySource` supplies observation time, provenance and bounded quota windows. Its adapter validates provider identity, cardinality, text, scope, duration, percentage and time before policy or storage. Implementations must supply authorised, quota-only data and canonicalise bounded text; account identity is not a quota label. The app and CLI supply no implementation and perform no runtime discovery.

`RationbookUI` contains the menu scene and presentation model. Its explicit configuration supports a service factory, reserve settings and status transformation. The executable is a small bootstrap. MCP and job attribution are deferred; any future integration must share the service and data model.

See [API.md](API.md) for versioned contracts and [PRIVACY.md](../PRIVACY.md) for storage and removal.

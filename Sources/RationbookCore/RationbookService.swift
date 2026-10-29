// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct DoctorCheck: Codable, Equatable, Sendable {
    public var name: String
    public var status: String
    public var detail: String
}

public struct DoctorReport: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var generatedAt: Date = Date()
    public var checks: [DoctorCheck]
}

// Settings use settingsLock; SQLiteStore serializes database access and adapters hold no mutable service state.
public final class RationbookService: @unchecked Sendable {
    public let paths: RationbookPaths
    public let store: SQLiteStore
    private let settingsLock = NSLock()
    private var storedReserveSettings: ReserveSettings
    public var reserveSettings: ReserveSettings {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return storedReserveSettings
    }
    private let codex: CodexAdapter
    private let claude: any ProviderAdapter
    public let startupErrors: [StructuredError]

    public init(
        paths: RationbookPaths = RationbookPaths(),
        reserveSettings: ReserveSettings = ReserveSettings(),
        anthropicCapacitySource: (any CapacitySource)? = nil
    ) throws {
        self.paths = paths
        let store: SQLiteStore
        var startupErrors: [StructuredError] = []
        do {
            store = try SQLiteStore(paths: paths)
        } catch let databaseError as SQLiteStoreError where databaseError.isCorruption {
            let backup = try Self.preserveDamagedDatabase(paths: paths)
            store = try SQLiteStore(paths: paths)
            startupErrors.append(StructuredError(
                code: "database_rebuilt",
                message: "The damaged Rationbook database was preserved at \(backup.lastPathComponent); a new local cache was created."
            ))
        }
        self.store = store
        self.storedReserveSettings = (try? store.value(forKey: "reserve_settings", as: ReserveSettings.self)) ?? reserveSettings
        self.codex = CodexAdapter()
        self.claude = anthropicCapacitySource.map { CapacitySourceAdapter(source: $0) }
            ?? ClaudeAdapter(paths: paths)
        self.startupErrors = startupErrors
    }

    public func updateReserveSettings(_ settings: ReserveSettings) throws {
        settingsLock.lock()
        storedReserveSettings = settings
        settingsLock.unlock()
        try store.set(settings, forKey: "reserve_settings")
    }

    public func retentionDays() -> Int {
        (try? store.value(forKey: "retention_days", as: Int.self)) ?? 60
    }

    public func updateRetentionDays(_ days: Int, now: Date = Date()) throws {
        let previous = retentionDays()
        try store.set(days, forKey: "retention_days")
        if days > 0, previous == 0 || days < previous {
            try store.pruneIfNeeded(retentionDays: days, now: now, force: true)
        }
    }

    public func notificationsEnabled() -> Bool {
        (try? store.value(forKey: "notifications_enabled", as: Bool.self)) ?? false
    }

    public func updateNotificationsEnabled(_ enabled: Bool) throws {
        try store.set(enabled, forKey: "notifications_enabled")
    }

    public func performMaintenance(now: Date = Date()) throws {
        let days = retentionDays()
        try store.pruneIfNeeded(retentionDays: days == 0 ? nil : days, now: now)
    }

    public func status(refresh: Bool = false, now: Date = Date()) -> StatusEnvelope {
        let activeReserveSettings = reserveSettings
        var providers: [ProviderStatus] = []
        providers.append(resolve(adapter: codex, refresh: refresh, now: now))
        providers.append(resolve(adapter: claude, refresh: refresh || !claude.capabilities.supportsOnDemandRefresh, now: now))
        providers = providers.map { provider in
            var calculated = ReservePolicy.apply(to: FreshnessPolicy.apply(to: provider, now: now), settings: activeReserveSettings)
            calculated.windows = calculated.windows.map { window in
                var copy = window
                let samples = (try? store.history(provider: provider.provider, windowID: window.id, limit: 500)) ?? []
                copy.resetObservedAt = ResetReconciler.observedReset(in: window, samples: samples)
                if let rate = BurnRateEstimator.estimate(samples: samples, now: now) {
                    copy.observedRate = rate
                    copy.reserveScenario = BurnRateEstimator.scenario(window: copy, rate: rate, now: now)
                }
                if copy.reserveScenario == nil {
                    copy.forecastUnavailableReason = Self.forecastUnavailableReason(window: copy, rate: copy.observedRate)
                }
                return copy
            }
            return calculated
        }
        var errors = startupErrors
        do {
            // Both the app's periodic refresh and CLI reads enforce the persisted retention policy.
            try performMaintenance(now: now)
        } catch {
            errors.append(StructuredError(code: "maintenance_failed", message: "Local history could not be pruned."))
        }
        return StatusEnvelope(generatedAt: now, providers: providers, errors: errors)
    }

    public func history(limit: Int = 100) throws -> [WindowSample] {
        try store.history(limit: limit)
    }

    public func history(provider: String, windowID: String, limit: Int = 100) throws -> [WindowSample] {
        try store.history(provider: provider, windowID: windowID, limit: limit)
    }

    public func forecast(refresh: Bool = false, now: Date = Date()) -> ForecastEnvelope {
        let envelope = status(refresh: refresh, now: now)
        return ForecastEnvelope(
            generatedAt: envelope.generatedAt,
            windows: envelope.providers.flatMap { provider in
                provider.windows.filter { $0.scope == "account" }.map { window in
                    ForecastWindow(
                        provider: provider.provider,
                        windowID: window.id,
                        displayLabel: window.displayLabel,
                        freshness: window.freshness,
                        scenario: window.reserveScenario,
                        unavailableReason: window.forecastUnavailableReason
                    )
                }
            }
        )
    }

    public func doctor() -> DoctorReport {
        var checks: [DoctorCheck] = []
        checks.append(executableCheck("Codex CLI", name: "codex"))
        checks.append(executableCheck("Claude Code", name: "claude"))
        checks.append(DoctorCheck(
            name: "Database",
            status: FileManager.default.fileExists(atPath: paths.database.path) ? "ok" : "waiting",
            detail: FileManager.default.fileExists(atPath: paths.database.path) ? "Local database available." : "Local database not created yet."
        ))
        for warning in startupErrors {
            checks.append(DoctorCheck(name: "Database recovery", status: "warning", detail: warning.message))
        }
        checks.append(DoctorCheck(
            name: "Claude quota feed",
            status: FileManager.default.fileExists(atPath: paths.claudeIntegration.path) ? "installed" : "not_installed",
            detail: FileManager.default.fileExists(atPath: paths.claudeObservation.path) ? "observation available" : "waiting for first observation"
        ))
        checks.append(DoctorCheck(
            name: "Model-capacity supplement",
            status: FileManager.default.fileExists(atPath: paths.modelCapacitySupplement.path) ? "installed" : "not_installed",
            detail: "Optional quota-only local input; Rationbook stores no provider credential."
        ))
        let live = status(refresh: false)
        for provider in live.providers {
            checks.append(DoctorCheck(
                name: provider.provider == "openai" ? "Codex quota" : "Claude aggregate quota",
                status: provider.state.rawValue,
                detail: provider.errors.first?.message ?? "\(provider.windows.count) quota window(s)"
            ))
        }
        return DoctorReport(checks: checks)
    }

    private func resolve(adapter: any ProviderAdapter, refresh: Bool, now: Date) -> ProviderStatus {
        if !refresh {
            if let cached = try? store.latestProvider(adapter.providerID) {
                let sanitized = removingTransientErrors(from: cached)
                if sanitized.errors != cached.errors { try? store.save(sanitized, recordHistory: false) }
                return FreshnessPolicy.apply(to: sanitized, now: now)
            }
            return adapter.detect()
        }
        guard let refreshLock = ProviderRefreshLock(provider: adapter.providerID, paths: paths) else {
            if var cached = try? store.latestProvider(adapter.providerID) {
                cached = FreshnessPolicy.apply(to: removingTransientErrors(from: cached), now: now)
                cached.state = cached.windows.isEmpty ? .unavailable : .partial
                appendUnique(StructuredError(code: "refresh_in_progress", message: "Another Rationbook process is refreshing this provider."), to: &cached.errors)
                return cached
            }
            var detected = adapter.detect()
            appendUnique(StructuredError(code: "refresh_in_progress", message: "Another Rationbook process is refreshing this provider."), to: &detected.errors)
            return detected
        }
        return withExtendedLifetime(refreshLock) {
            do {
                var status = try adapter.fetch(now: now)
                status = reconcileResets(in: status, now: now)
                try store.save(status)
                return status
            } catch {
                if var cached = try? store.latestProvider(adapter.providerID) {
                    cached = FreshnessPolicy.apply(to: removingTransientErrors(from: cached), now: now)
                    cached.state = cached.windows.isEmpty ? .unavailable : .partial
                    let (_, structuredError) = ProviderErrorMapper.structured(error)
                    appendUnique(StructuredError(code: "refresh_failed", message: structuredError.message), to: &cached.errors)
                    appendUnique(structuredError, to: &cached.errors)
                    return cached
                }
                return ProviderErrorMapper.status(
                    provider: adapter.providerID,
                    agentLabel: adapter.providerID == "openai" ? "OpenAI" : "Anthropic",
                    capabilities: adapter.capabilities,
                    source: SourceMetadata(name: adapter.providerID, documentation: "unknown", maturity: "unknown"),
                    error: error
                )
            }
        }
    }

    private func reconcileResets(in provider: ProviderStatus, now: Date) -> ProviderStatus {
        guard let previous = try? store.latestProvider(provider.provider) else { return provider }
        return ResetReconciler.reconcile(current: provider, previous: previous, now: now)
    }

    private func removingTransientErrors(from provider: ProviderStatus) -> ProviderStatus {
        var copy = provider
        let transient = Set(["refresh_failed", "refresh_in_progress"])
        copy.errors.removeAll { transient.contains($0.code) }
        return copy
    }

    private func appendUnique(_ error: StructuredError, to errors: inout [StructuredError]) {
        if !errors.contains(where: { $0.code == error.code }) { errors.append(error) }
    }

    private static func forecastUnavailableReason(window: QuotaWindow, rate: ObservedRate?) -> String {
        if let reason = window.invalidationReason { return reason }
        if window.freshness == .stale || window.freshness == .unknown { return "stale_latest_observation" }
        guard let rate else { return "insufficient_recent_samples" }
        if rate.forecastBurnPPPerWallHour <= 0 { return "no_positive_burn" }
        if window.policy?.state != .available { return "reserve_policy_not_available" }
        return "insufficient_forecast_confidence"
    }

    private func executableCheck(_ label: String, name: String) -> DoctorCheck {
        do {
            _ = try ExecutableLocator.locate(name)
            return DoctorCheck(name: label, status: "found", detail: "Available and passed executable safety checks.")
        } catch ProcessRunnerError.unsafeExecutable {
            return DoctorCheck(name: label, status: "unsafe", detail: "Candidate rejected by executable safety checks.")
        } catch {
            return DoctorCheck(name: label, status: "missing", detail: "No safe executable was found.")
        }
    }

    private static func preserveDamagedDatabase(paths: RationbookPaths) throws -> URL {
        try paths.prepare()
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = paths.root.appendingPathComponent("rationbook.sqlite3.damaged-\(stamp)")
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: paths.database.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = URL(fileURLWithPath: backup.path + suffix)
            try fileManager.moveItem(at: source, to: destination)
        }
        return backup
    }
}

public enum ResetReconciler {
    public static func observedReset(in window: QuotaWindow, samples: [WindowSample]) -> Date? {
        var observed = window.resetObservedAt
        let ordered = samples.filter { $0.windowID == window.id }.sorted { $0.firstObservedAt < $1.firstObservedAt }
        for (previous, current) in zip(ordered, ordered.dropFirst()) {
            guard let oldReset = previous.expectedResetsAt, let newReset = current.expectedResetsAt,
                  newReset.timeIntervalSince(oldReset) > 60,
                  current.firstObservedAt <= window.observedAt else { continue }
            // A coalesced sample's first observation marks the rollover, not its latest refresh.
            if current.firstObservedAt > (observed ?? .distantPast) {
                observed = current.firstObservedAt
            }
        }
        return observed
    }

    public static func reconcile(current provider: ProviderStatus, previous: ProviderStatus, now: Date) -> ProviderStatus {
        var copy = provider
        var sawCounterDiscontinuity = false
        copy.windows = provider.windows.map { window in
            guard let old = previous.windows.first(where: { $0.id == window.id }) else { return window }
            let resetMovedForward: Bool = {
                guard let oldReset = old.expectedResetsAt, let newReset = window.expectedResetsAt else { return false }
                return newReset.timeIntervalSince(oldReset) > 60
            }()
            var result = window
            result.resetObservedAt = resetMovedForward ? now : old.resetObservedAt
            if !resetMovedForward, old.usedPercent - window.usedPercent > 2 { sawCounterDiscontinuity = true }
            return result
        }
        if sawCounterDiscontinuity {
            appendUnique(StructuredError(
                code: "counter_discontinuity",
                message: "A quota counter decreased without a confirmed reset schedule rollover; forecasting starts a new segment."
            ), to: &copy.errors)
        }
        let currentIDs = Set(copy.windows.map(\.id))
        for old in previous.windows where !currentIDs.contains(old.id) {
            guard let expectedReset = old.expectedResetsAt, expectedReset <= now else { continue }
            var tombstone = old
            tombstone.freshness = .stale
            tombstone.invalidationReason = "quota_window_absent_after_reset"
            tombstone.resetObservedAt = old.resetObservedAt ?? now
            tombstone.observedRate = nil
            tombstone.reserveScenario = nil
            tombstone.forecastUnavailableReason = "quota_window_absent_after_reset"
            copy.windows.append(tombstone)
            copy.state = .partial
            appendUnique(StructuredError(
                code: "quota_window_absent_after_reset",
                message: "A previously observed quota window disappeared after its expected reset; it is retained as stale evidence until the provider reports it again."
            ), to: &copy.errors)
        }
        return copy
    }

    private static func appendUnique(_ error: StructuredError, to errors: inout [StructuredError]) {
        if !errors.contains(where: { $0.code == error.code }) { errors.append(error) }
    }
}

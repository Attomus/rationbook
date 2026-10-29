// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Testing
@testable import RationbookCore

@Suite struct ForecastTests {
    @Test func usesProviderFreshnessLimits() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(FreshnessPolicy.classify(provider: "openai", observedAt: now.addingTimeInterval(-120), now: now) == .fresh)
        #expect(FreshnessPolicy.classify(provider: "openai", observedAt: now.addingTimeInterval(-121), now: now) == .aging)
        #expect(FreshnessPolicy.classify(provider: "anthropic", observedAt: now.addingTimeInterval(-3_601), now: now) == .stale)
    }

    @Test func appliesReservePolicy() {
        let time = Date()
        var status = provider(observedAt: time, used: 97)
        var applied = ReservePolicy.apply(to: status, settings: ReserveSettings(codexShort: 5))
        #expect(applied.windows[0].policy?.safeRemainingPercent == 0)
        #expect(applied.windows[0].policy?.state == .exhausted)
        #expect(applied.planningState == .exhausted)
        #expect(applied.limitingWindowID == "openai:codex:300")
        status.windows[0].freshness = .stale
        applied = ReservePolicy.apply(to: status, settings: ReserveSettings())
        #expect(applied.windows[0].policy?.state == .uncertain)
        #expect(applied.planningState == .uncertain)
    }

    @Test func distinguishesCapacityRisk() {
        let now = Date()
        var window = QuotaWindow(
            id: "w",
            displayLabel: "weekly",
            observedAt: now,
            freshness: .fresh,
            usedPercent: 75,
            dataQuality: .authoritative
        )
        window.policy = WindowPolicy(reservePercent: 10, safeRemainingPercent: 15, state: .available)
        #expect(ReservePolicy.capacityRisk(for: window) == .normal)

        window.remainingPercent = 20
        window.policy?.safeRemainingPercent = 10
        #expect(ReservePolicy.capacityRisk(for: window) == .warning)

        window.remainingPercent = 10
        window.policy = WindowPolicy(reservePercent: 10, safeRemainingPercent: 0, state: .exhausted)
        #expect(ReservePolicy.capacityRisk(for: window) == .critical)

        window.freshness = .stale
        window.policy?.state = .uncertain
        #expect(ReservePolicy.capacityRisk(for: window) == .uncertain)
    }

    @Test func scalesTrendMovement() throws {
        let ordinary = try #require(TrendScale.domain(values: [90, 88, 85]))
        #expect(abs(ordinary.lowerBound - 77.5) < 0.001)
        #expect(abs(ordinary.upperBound - 97.5) < 0.001)
        #expect(abs(ordinary.position(for: 85) - 0.375) < 0.001)

        let nearFull = try #require(TrendScale.domain(values: [99, 100]))
        #expect(nearFull.lowerBound == 80)
        #expect(nearFull.upperBound == 100)

        let fullRange = try #require(TrendScale.domain(values: [0, 100]))
        #expect(fullRange.lowerBound == 0)
        #expect(fullRange.upperBound == 100)
        #expect(TrendScale.isUpwardDiscontinuity(previous: 36, current: 100))
        #expect(!TrendScale.isUpwardDiscontinuity(previous: 36, current: 38))
    }

    @Test func confirmsScheduledReset() {
        let previous = Date(timeIntervalSince1970: 1_000)
        let current = Date(timeIntervalSince1970: 2_000)
        let scheduled = Date(timeIntervalSince1970: 1_500)
        #expect(TrendScale.resetEventDate(
            between: previous,
            and: current,
            scheduledAt: scheduled,
            observedAt: nil
        ) == scheduled)
        #expect(TrendScale.resetEventDate(
            between: previous,
            and: current,
            scheduledAt: Date(timeIntervalSince1970: 2_500),
            observedAt: nil
        ) == nil)
    }

    @Test func requiresContinuousHistory() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let samples = (0..<6).map { index in
            WindowSample(
                provider: "openai", windowID: "w", usedPercent: Double(index) * 2,
                remainingPercent: 100 - Double(index) * 2, expectedResetsAt: nil,
                firstObservedAt: start.addingTimeInterval(Double(index) * 900),
                lastObservedAt: start.addingTimeInterval(Double(index) * 900), sampleCount: 1, freshness: .fresh
            )
        }
        let result = BurnRateEstimator.estimate(samples: samples, now: start.addingTimeInterval(4_500))
        #expect(result?.netChangePPPerWallHour == 8)
        #expect(result?.confidence == .high)
        #expect(result?.sampleCount == 6)
    }

    @Test func splitsHistoryAtReset() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let values = [80.0, 82, 84, 5, 6]
        let samples = values.enumerated().map { index, value in
            WindowSample(
                provider: "openai", windowID: "w", usedPercent: value, remainingPercent: 100 - value,
                expectedResetsAt: nil, firstObservedAt: start.addingTimeInterval(Double(index) * 900),
                lastObservedAt: start.addingTimeInterval(Double(index) * 900), sampleCount: 1, freshness: .fresh
            )
        }
        #expect(BurnRateEstimator.estimate(samples: samples, now: start.addingTimeInterval(3_600)) == nil)
    }

    @Test func reportsNextReset() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var window = QuotaWindow(id: "w", displayLabel: "weekly", observedAt: now, freshness: .fresh, usedPercent: 50, expectedResetsAt: now.addingTimeInterval(3_600), dataQuality: .authoritative)
        window.policy = WindowPolicy(reservePercent: 10, safeRemainingPercent: 40, state: .available)
        let rate = ObservedRate(netChangePPPerWallHour: 10, forecastBurnPPPerWallHour: 10, confidence: .medium, sampleCount: 3, intervalStartedAt: now.addingTimeInterval(-3_600))
        #expect(BurnRateEstimator.scenario(window: window, rate: rate, now: now)?.firstEvent == "expected_reset")
    }

    @Test func comparesCapacityWithTime() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var window = QuotaWindow(
            id: "w",
            displayLabel: "7 day",
            durationSeconds: 7 * 24 * 60 * 60,
            observedAt: now,
            freshness: .fresh,
            usedPercent: 7,
            expectedResetsAt: now.addingTimeInterval(6 * 24 * 60 * 60),
            dataQuality: .authoritative
        )
        window.policy = WindowPolicy(reservePercent: 5, safeRemainingPercent: 88, state: .available)

        let pace = try #require(PaceEstimator.estimate(window: window, now: now))
        #expect(abs(pace.targetRemainingPercent - 86.428_571) < 0.001)
        #expect(abs(pace.deltaPercent - 6.571_429) < 0.001)
        #expect(abs(pace.sustainablePercentPerHour - 0.611_111) < 0.001)
        #expect(pace.status == .ahead)
    }

    @Test func usesObservedResetTiming() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var window = QuotaWindow(
            id: "anthropic:claude_account:18000",
            displayLabel: "5 hour",
            durationSeconds: 18_000,
            observedAt: now.addingTimeInterval(-60),
            freshness: .aging,
            usedPercent: 54,
            expectedResetsAt: now.addingTimeInterval(3_600),
            dataQuality: .localObserved
        )
        window.policy = WindowPolicy(reservePercent: 10, safeRemainingPercent: 36, state: .available)

        let pace = try #require(PaceEstimator.estimate(window: window, now: now))
        #expect(abs(pace.targetRemainingPercent - 28) < 0.001)

        window.dataQuality = .inferred
        #expect(PaceEstimator.estimate(window: window, now: now) == nil)
    }

    @Test func requiresReliableResetTiming() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var window = QuotaWindow(
            id: "w",
            displayLabel: "7 day",
            durationSeconds: 7 * 24 * 60 * 60,
            observedAt: now,
            freshness: .stale,
            usedPercent: 7,
            expectedResetsAt: now.addingTimeInterval(6 * 24 * 60 * 60),
            dataQuality: .authoritative
        )
        window.policy = WindowPolicy(reservePercent: 5, safeRemainingPercent: 88, state: .uncertain)
        #expect(PaceEstimator.estimate(window: window, now: now) == nil)

        window.freshness = .fresh
        window.policy?.state = .available
        window.expectedResetsAt = nil
        #expect(PaceEstimator.estimate(window: window, now: now) == nil)
    }

    @Test func rejectsStaleHistory() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let samples = (0..<6).map { index in
            WindowSample(
                provider: "openai", windowID: "w", usedPercent: Double(index) * 2,
                remainingPercent: 100 - Double(index) * 2, expectedResetsAt: nil,
                firstObservedAt: start.addingTimeInterval(Double(index) * 900),
                lastObservedAt: start.addingTimeInterval(Double(index) * 900), sampleCount: 1, freshness: .fresh
            )
        }
        let now = start.addingTimeInterval(4_500 + 901)
        let rate = BurnRateEstimator.estimate(samples: samples, now: now)
        #expect(rate?.confidence == .low)
        var window = QuotaWindow(id: "w", displayLabel: "5 hour", observedAt: samples.last!.lastObservedAt, freshness: .stale, usedPercent: 10, dataQuality: .authoritative)
        window.policy = WindowPolicy(reservePercent: 5, safeRemainingPercent: 85, state: .uncertain)
        #expect(rate.flatMap { BurnRateEstimator.scenario(window: window, rate: $0, now: now) } == nil)
    }

    @Test func separatesSpendAndQuota() throws {
        let observation = try ClaudeAdapter.observation(fromStatusLine: fixture("claude-both"), observedAt: Date(timeIntervalSince1970: 100))
        let normalized = ClaudeAdapter.normalize(observation, now: Date(timeIntervalSince1970: 200))
        let applied = ReservePolicy.apply(to: normalized, settings: ReserveSettings())
        #expect(applied.windows.first(where: { $0.displayLabel == "Spend limit" })?.scope == "spend")
        #expect(applied.limitingWindowID != "anthropic:spend:spend_limit")
    }

    @Test func reportsPartialFreshness() {
        var status = provider(observedAt: Date(timeIntervalSince1970: 10_000), used: 10)
        status.windows.append(QuotaWindow(id: "old", displayLabel: "old", observedAt: Date(timeIntervalSince1970: 0), usedPercent: 20, dataQuality: .authoritative))
        #expect(FreshnessPolicy.apply(to: status, now: Date(timeIntervalSince1970: 10_000)).state == .partial)
    }

    @Test func agesMenuSummary() {
        let observed = Date(timeIntervalSince1970: 10_000)
        let fresh = FreshnessPolicy.apply(to: provider(observedAt: observed, used: 25), now: observed)
        let stale = FreshnessPolicy.apply(to: fresh, now: observed.addingTimeInterval(901))
        #expect(MenuBarSummary.title(providers: [fresh]) == "O 75%")
        #expect(MenuBarSummary.title(providers: [stale]) == "O 75%~")
    }

    @Test func hidesHistoricalWindowInUI() {
        var status = provider(observedAt: Date(), used: 25)
        status.windows.append(QuotaWindow(
            id: "openai:codex_bengalfox:0:300",
            providerID: "codex_bengalfox",
            providerLabel: "GPT-5.3-Codex-Spark",
            displayLabel: "GPT-5.3-Codex-Spark",
            durationSeconds: 18_000,
            observedAt: Date(),
            freshness: .fresh,
            usedPercent: 90,
            dataQuality: .authoritative
        ))
        #expect(status.windows.count == 2)
        #expect(HumanPresentation.visibleWindows(for: status).map(\.id) == ["openai:codex:300"])
        #expect(MenuBarSummary.title(providers: [status]) == "O 75%")
    }

    @Test func keepsHiddenWindowsInJSON() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        var status = provider(observedAt: now, used: 25)
        status.windows.append(QuotaWindow(
            id: "openai:gpt-reserve:604800",
            providerID: "gpt-reserve",
            providerLabel: "GPT reserve",
            displayLabel: "GPT reserve",
            durationSeconds: 604_800,
            observedAt: now,
            freshness: .fresh,
            usedPercent: 5,
            dataQuality: .authoritative
        ))
        var preferences = WindowDisplayPreferences()
        preferences.setVisible(false, providerID: status.provider, windowID: "openai:gpt-reserve:604800")

        #expect(preferences.visibleWindows(for: status).map(\.id) == ["openai:codex:300"])
        #expect(status.windows.count == 2)

        let encoded = try RationbookJSON.encoder().encode(StatusEnvelope(generatedAt: now, providers: [status]))
        let decoded = try RationbookJSON.decoder().decode(StatusEnvelope.self, from: encoded)
        #expect(decoded.providers[0].windows.map(\.id).contains("openai:gpt-reserve:604800"))
        #expect(decoded.providers[0].windows.count == 2)
    }

    @Test func persistsResetEvidence() {
        let now = Date(timeIntervalSince1970: 30_000)
        var previous = provider(observedAt: now.addingTimeInterval(-60), used: 80)
        previous.windows[0].expectedResetsAt = now.addingTimeInterval(600)
        var decreased = provider(observedAt: now, used: 10)
        decreased.windows[0].expectedResetsAt = previous.windows[0].expectedResetsAt
        let discontinuity = ResetReconciler.reconcile(current: decreased, previous: previous, now: now)
        #expect(discontinuity.windows[0].resetObservedAt == nil)
        #expect(discontinuity.errors.contains { $0.code == "counter_discontinuity" })

        var rolled = decreased
        rolled.windows[0].expectedResetsAt = now.addingTimeInterval(18_000)
        let reset = ResetReconciler.reconcile(current: rolled, previous: previous, now: now)
        #expect(reset.windows[0].resetObservedAt == now)
        let later = ResetReconciler.reconcile(current: rolled, previous: reset, now: now.addingTimeInterval(60))
        #expect(later.windows[0].resetObservedAt == now)

        let nextReset = now.addingTimeInterval(18_001)
        rolled.windows[0].expectedResetsAt = nextReset.addingTimeInterval(18_000)
        let second = ResetReconciler.reconcile(current: rolled, previous: later, now: nextReset)
        #expect(second.windows[0].resetObservedAt == nextReset)
    }

    @Test func recoversResetFromHistory() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try RationbookService(paths: RationbookPaths(root: root))
        let now = Date(timeIntervalSince1970: 1_000_000)
        let oldObservedReset = now.addingTimeInterval(-3 * 86_400)
        let resetObserved = now.addingTimeInterval(-8 * 3_600)
        var snapshot = provider(observedAt: resetObserved.addingTimeInterval(-300), used: 53)
        snapshot.windows[0].expectedResetsAt = now.addingTimeInterval(3 * 86_400)
        snapshot.windows[0].resetObservedAt = oldObservedReset
        try service.store.save(snapshot)

        snapshot.windows[0].observedAt = resetObserved
        snapshot.windows[0].expectedResetsAt = resetObserved.addingTimeInterval(7 * 86_400)
        snapshot.windows[0].usedPercent = 0
        snapshot.windows[0].remainingPercent = 100
        try service.store.save(snapshot)
        snapshot.windows[0].observedAt = now.addingTimeInterval(-300)
        try service.store.save(snapshot)
        snapshot.windows[0].observedAt = now
        snapshot.windows[0].usedPercent = 1
        snapshot.windows[0].remainingPercent = 99
        try service.store.save(snapshot)

        let current = try #require(service.status(now: now).providers.first { $0.provider == "openai" })
        #expect(current.windows[0].resetObservedAt == resetObserved)
        #expect(current.windows[0].remainingPercent == 99)
        let again = try #require(service.status(now: now.addingTimeInterval(60)).providers.first { $0.provider == "openai" })
        #expect(again.windows[0].resetObservedAt == resetObserved)
        let history = try service.history(provider: "openai", windowID: snapshot.windows[0].id)
        #expect(history.count == 3)
        #expect(history.first { $0.usedPercent == 0 }?.sampleCount == 2)
    }

    @Test func requiresResetScheduleRollover() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try RationbookService(paths: RationbookPaths(root: root))
        let now = Date(timeIntervalSince1970: 1_000_000)
        var snapshot = provider(observedAt: now.addingTimeInterval(-300), used: 53)
        snapshot.windows[0].expectedResetsAt = now.addingTimeInterval(3 * 86_400)
        try service.store.save(snapshot)
        snapshot.windows[0].observedAt = now
        snapshot.windows[0].usedPercent = 0
        snapshot.windows[0].remainingPercent = 100
        try service.store.save(snapshot)
        let current = try #require(service.status(now: now).providers.first { $0.provider == "openai" })
        #expect(current.windows[0].resetObservedAt == nil)
    }

    @Test func retainsMissingWindowUncertainty() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 30_000)
        let service = try RationbookService(paths: RationbookPaths(root: root))
        var previous = provider(observedAt: now.addingTimeInterval(-60), used: 80)
        previous.windows[0].expectedResetsAt = now.addingTimeInterval(-1)
        var current = provider(observedAt: now, used: 10)
        current.windows[0].id = "surviving-window"
        let reconciled = ResetReconciler.reconcile(current: current, previous: previous, now: now)
        try service.store.save(reconciled)
        // Exercise persisted evidence through the same freshness and reserve pipeline as public JSON.
        let cached = try #require(service.status(now: now).providers.first { $0.provider == "openai" })
        let missing = try #require(cached.windows.first { $0.id == previous.windows[0].id })
        #expect(missing.freshness == .stale)
        #expect(missing.policy?.state == .uncertain)
        #expect(cached.planningState == .uncertain)
        #expect(missing.invalidationReason == "quota_window_absent_after_reset")

        let forecast = service.forecast(now: now)
        #expect(forecast.windows.first { $0.windowID == missing.id }?.unavailableReason == "quota_window_absent_after_reset")

        previous.windows[0].observedAt = now.addingTimeInterval(60)
        current.windows.append(previous.windows[0])
        let restored = ResetReconciler.reconcile(current: current, previous: cached, now: now.addingTimeInterval(60))
        try service.store.save(restored)
        let refreshed = try #require(service.status(now: now.addingTimeInterval(60)).providers.first { $0.provider == "openai" })
        #expect(refreshed.planningState == .available)
        #expect(refreshed.windows.allSatisfy { $0.invalidationReason == nil })
    }

    @Test func clearsTransientErrors() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try RationbookService(paths: RationbookPaths(root: root))
        var cached = provider(observedAt: Date(), used: 20)
        cached.errors = [
            StructuredError(code: "refresh_failed", message: "old"),
            StructuredError(code: "refresh_failed", message: "older"),
            StructuredError(code: "refresh_in_progress", message: "old"),
        ]
        try service.store.save(cached)
        for _ in 0..<10 {
            let returned = service.status(refresh: false)
            #expect(returned.providers.first(where: { $0.provider == "openai" })?.errors.isEmpty == true)
        }
        #expect(try service.store.latestProvider("openai")?.errors.isEmpty == true)
    }

    @Test func separatesHistoricalReadings() {
        var status = provider(observedAt: Date(), used: 3)
        status.state = .partial
        var previous = status.windows[0]
        previous.id = "legacy"
        previous.providerID = "codex_bengalfox"
        previous.freshness = .stale
        status.windows.append(previous)
        status.errors = [StructuredError(code: "quota_window_absent_after_reset", message: "Previous window absent")]
        #expect(HumanPresentation.currentState(for: status) == .available)
        #expect(HumanPresentation.historicalWindows(for: status).map(\.id) == ["legacy"])
        #expect(status.windows.count == 2)
        status.errors.append(StructuredError(code: "refresh_failed", message: "Refresh failed"))
        #expect(HumanPresentation.currentState(for: status) == .partial)
        status.windows[0].freshness = .stale
        #expect(HumanPresentation.currentState(for: status) == .stale)
    }

    @Test func retainsStaleAccountReading() {
        let now = Date()
        var status = provider(observedAt: now, used: 2, freshness: .stale)
        status.provider = "anthropic"
        var model = status.windows[0]
        model.id = "model-weekly"
        model.scope = "model"
        model.expectedResetsAt = now.addingTimeInterval(-1)
        status.windows.append(model)
        #expect(HumanPresentation.currentWindows(for: status, now: now).map(\.id) == [status.windows[0].id])
        #expect(HumanPresentation.historicalWindows(for: status, now: now).map(\.id) == [model.id])
        status.windows[1].freshness = .fresh
        #expect(HumanPresentation.currentWindows(for: status, now: now).count == 2)
        #expect(status.windows.count == 2)
    }
}

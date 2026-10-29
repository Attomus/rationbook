// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum BurnRateEstimator {
    public static func estimate(samples: [WindowSample], now: Date = Date()) -> ObservedRate? {
        let sorted = samples.sorted { $0.lastObservedAt < $1.lastObservedAt }
        guard sorted.count >= 3 else { return nil }
        let newest = sorted.last!
        let cutoff = max(newest.lastObservedAt.addingTimeInterval(-6 * 3_600), now.addingTimeInterval(-6 * 3_600))
        var segment = sorted.filter { $0.lastObservedAt >= cutoff }
        guard segment.count >= 3 else { return nil }

        var startIndex = 0
        for index in 1..<segment.count {
            let gap = segment[index].firstObservedAt.timeIntervalSince(segment[index - 1].lastObservedAt)
            let decrease = segment[index].usedPercent - segment[index - 1].usedPercent
            if gap > 7_200 || decrease < -2 {
                startIndex = index
            }
        }
        segment = Array(segment[startIndex...])
        guard segment.count >= 3, let first = segment.first, let last = segment.last else { return nil }
        let hours = last.lastObservedAt.timeIntervalSince(first.firstObservedAt) / 3_600
        guard hours >= 0.25 else { return nil }
        let slope = (last.usedPercent - first.usedPercent) / hours
        let currentFreshness = FreshnessPolicy.classify(provider: newest.provider, observedAt: newest.lastObservedAt, now: now)
        let confidence: EstimateConfidence
        if segment.count >= 6, hours >= 1, currentFreshness == .fresh {
            confidence = .high
        } else if currentFreshness != .stale && currentFreshness != .unknown {
            confidence = .medium
        } else {
            confidence = .low
        }
        return ObservedRate(
            netChangePPPerWallHour: slope,
            forecastBurnPPPerWallHour: max(0, slope),
            confidence: confidence,
            sampleCount: segment.count,
            intervalStartedAt: first.firstObservedAt
        )
    }

    public static func scenario(window: QuotaWindow, rate: ObservedRate, now: Date = Date()) -> ReserveScenario? {
        guard [.fresh, .aging].contains(window.freshness),
              [.high, .medium].contains(rate.confidence),
              rate.forecastBurnPPPerWallHour > 0,
              let policy = window.policy, policy.state == .available else { return nil }
        let safe = policy.safeRemainingPercent
        let untilReserve = safe / rate.forecastBurnPPPerWallHour
        let untilReset = window.expectedResetsAt.map { max(0, $0.timeIntervalSince(now) / 3_600) }
        let firstEvent = untilReset.map { $0 <= untilReserve ? "expected_reset" : "reserve" } ?? "reserve"
        return ReserveScenario(hoursUntilReserve: untilReserve, hoursUntilExpectedReset: untilReset, firstEvent: firstEvent, confidence: rate.confidence)
    }
}

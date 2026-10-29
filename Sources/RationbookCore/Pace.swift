// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum PaceStatus: String, Equatable, Sendable {
    case ahead
    case onPace = "on_pace"
    case behind
}

public struct WindowPace: Equatable, Sendable {
    public var targetRemainingPercent: Double
    public var deltaPercent: Double
    public var sustainablePercentPerHour: Double
    public var status: PaceStatus

    public init(
        targetRemainingPercent: Double,
        deltaPercent: Double,
        sustainablePercentPerHour: Double,
        status: PaceStatus
    ) {
        self.targetRemainingPercent = targetRemainingPercent
        self.deltaPercent = deltaPercent
        self.sustainablePercentPerHour = sustainablePercentPerHour
        self.status = status
    }
}

public enum PaceEstimator {
    public static func estimate(window: QuotaWindow, now: Date = Date()) -> WindowPace? {
        guard [.fresh, .aging].contains(window.freshness),
              window.dataQuality != .inferred,
              let durationSeconds = window.durationSeconds, durationSeconds > 0,
              let reset = window.expectedResetsAt, reset > now,
              let policy = window.policy,
              ![.uncertain, .unavailable].contains(policy.state) else { return nil }

        let secondsRemaining = reset.timeIntervalSince(now)
        let timeFractionRemaining = min(max(secondsRemaining / Double(durationSeconds), 0), 1)
        let usableCapacity = max(0, 100 - policy.reservePercent)
        let targetRemaining = policy.reservePercent + usableCapacity * timeFractionRemaining
        let delta = window.remainingPercent - targetRemaining
        let hoursRemaining = secondsRemaining / 3_600
        let sustainableRate = max(0, policy.safeRemainingPercent) / hoursRemaining

        let status: PaceStatus
        if delta > 2 {
            status = .ahead
        } else if delta < -2 {
            status = .behind
        } else {
            status = .onPace
        }

        return WindowPace(
            targetRemainingPercent: targetRemaining,
            deltaPercent: delta,
            sustainablePercentPerHour: sustainableRate,
            status: status
        )
    }
}

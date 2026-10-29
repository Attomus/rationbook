// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct ReserveSettings: Codable, Equatable, Sendable {
    public var codexShort: Double
    public var codexLong: Double
    public var claudeShort: Double
    public var claudeLong: Double

    public init(codexShort: Double = 5, codexLong: Double = 10, claudeShort: Double = 5, claudeLong: Double = 5) {
        self.codexShort = codexShort
        self.codexLong = codexLong
        self.claudeShort = claudeShort
        self.claudeLong = claudeLong
    }

    public func reserve(provider: String, durationSeconds: Int?) -> Double {
        guard let durationSeconds else { return 0 }
        let isLong = durationSeconds >= 24 * 60 * 60
        switch provider {
        case "openai": return isLong ? codexLong : codexShort
        case "anthropic": return isLong ? claudeLong : claudeShort
        default: return 0
        }
    }
}

public enum CapacityRisk: Equatable, Sendable {
    case normal
    case warning
    case critical
    case uncertain
}

public enum ReservePolicy {
    public static func apply(to provider: ProviderStatus, settings: ReserveSettings) -> ProviderStatus {
        var copy = provider
        copy.windows = provider.windows.map { window in
            var result = window
            let reserve = max(0, settings.reserve(provider: provider.provider, durationSeconds: window.durationSeconds))
            let safe = max(0, window.remainingPercent - reserve)
            let state: PolicyState
            if window.freshness == .stale || window.freshness == .unknown {
                state = .uncertain
            } else if safe <= 0 {
                state = .exhausted
            } else {
                state = .available
            }
            result.policy = WindowPolicy(reservePercent: reserve, safeRemainingPercent: safe, state: state)
            return result
        }
        copy.modelSpecificCapacity = provider.modelSpecificCapacity ?? (provider.provider == "anthropic" ? "unknown" : nil)
        let capacityWindows = copy.windows.filter { $0.scope == "account" }
        if capacityWindows.isEmpty {
            copy.planningState = .unavailable
            copy.limitingWindowID = nil
        } else if capacityWindows.contains(where: { $0.freshness == .stale || $0.freshness == .unknown }) {
            copy.planningState = .uncertain
            copy.limitingWindowID = nil
        } else {
            let limiting = capacityWindows.filter { $0.policy != nil }.min { left, right in
                let leftSafe = left.policy?.safeRemainingPercent ?? .infinity
                let rightSafe = right.policy?.safeRemainingPercent ?? .infinity
                if leftSafe != rightSafe { return leftSafe < rightSafe }
                return (left.expectedResetsAt ?? .distantPast) > (right.expectedResetsAt ?? .distantPast)
            }
            copy.limitingWindowID = limiting?.id
            copy.planningState = limiting?.policy?.state ?? .unavailable
        }
        return copy
    }

    public static func capacityRisk(for window: QuotaWindow) -> CapacityRisk {
        guard [.fresh, .aging].contains(window.freshness),
              let policy = window.policy,
              ![.uncertain, .unavailable].contains(policy.state) else { return .uncertain }
        if policy.state == .exhausted || window.remainingPercent <= policy.reservePercent {
            return .critical
        }
        let approachMargin = max(5, policy.reservePercent)
        if policy.safeRemainingPercent <= approachMargin {
            return .warning
        }
        return .normal
    }
}

public enum ClaudeRefreshInterval: Int, CaseIterable, Sendable {
    case manual = 0
    case fiveMinutes = 5
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case hourly = 60

    public func isDue(lastAttempt: Date?, observations: [Date], now: Date = Date()) -> Bool {
        guard self != .manual else { return false }
        let interval = TimeInterval(rawValue * 60)
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < interval { return false }
        return observations.isEmpty || observations.contains { now.timeIntervalSince($0) >= interval }
    }
}

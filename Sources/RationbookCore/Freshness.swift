// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum FreshnessPolicy {
    public static func classify(provider: String, observedAt: Date, now: Date = Date()) -> Freshness {
        let age = max(0, now.timeIntervalSince(observedAt))
        switch provider {
        case "openai":
            if age <= 120 { return .fresh }
            if age <= 900 { return .aging }
            return .stale
        case "anthropic":
            if age <= 600 { return .fresh }
            if age <= 3_600 { return .aging }
            return .stale
        default:
            return .unknown
        }
    }

    public static func apply(to provider: ProviderStatus, now: Date = Date()) -> ProviderStatus {
        var copy = provider
        copy.windows = provider.windows.map { window in
            var result = window
            if result.invalidationReason != nil {
                result.freshness = .stale
            } else {
                result.freshness = classify(provider: provider.provider, observedAt: window.observedAt, now: now)
            }
            return result
        }
        if !copy.windows.isEmpty, copy.windows.allSatisfy({ $0.freshness == .stale }) {
            copy.state = .stale
        } else if copy.windows.contains(where: { $0.freshness == .stale || $0.freshness == .unknown }) {
            copy.state = .partial
        }
        return copy
    }
}

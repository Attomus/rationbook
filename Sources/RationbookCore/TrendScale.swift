// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct TrendDomain: Equatable, Sendable {
    public var lowerBound: Double
    public var upperBound: Double

    public init(lowerBound: Double, upperBound: Double) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public func position(for value: Double) -> Double {
        let clamped = min(max(value, lowerBound), upperBound)
        return (clamped - lowerBound) / (upperBound - lowerBound)
    }
}

public enum TrendScale {
    public static func isUpwardDiscontinuity(previous: Double, current: Double) -> Bool {
        current - previous > 2
    }

    public static func resetEventDate(
        between previous: Date,
        and current: Date,
        scheduledAt: Date?,
        observedAt: Date?
    ) -> Date? {
        [observedAt, scheduledAt]
            .compactMap { $0 }
            .first { $0 >= previous && $0 <= current }
    }

    public static func domain(values: [Double], minimumSpan: Double = 20) -> TrendDomain? {
        let values = values.map { min(max($0, 0), 100) }
        guard let low = values.min(), let high = values.max() else { return nil }
        let rawSpan = high - low
        let span = min(100, max(minimumSpan, rawSpan * 1.2))
        let midpoint = (low + high) / 2
        var lower = midpoint - span / 2
        var upper = midpoint + span / 2
        if lower < 0 {
            upper -= lower
            lower = 0
        }
        if upper > 100 {
            lower -= upper - 100
            upper = 100
        }
        return TrendDomain(lowerBound: max(0, lower), upperBound: min(100, upper))
    }
}

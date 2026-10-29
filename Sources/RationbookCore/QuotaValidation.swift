// SPDX-License-Identifier: Apache-2.0

import CoreFoundation
import Foundation

/// Reject corrupt observations before they can replace usable quota history.
enum QuotaValidation {
    static func scalar(_ value: Any) throws -> Double {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { throw invalid() }
        return number.doubleValue
    }

    static func percentage(_ value: Double) throws {
        // Preserve provider overage (for example 110.5%), without admitting
        // unbounded arithmetic or implausible percentages into history.
        guard value.isFinite, (0...10_000).contains(value) else { throw invalid() }
    }

    static func timestamp(_ value: Double) throws {
        guard value.isFinite, (0...253_402_300_799).contains(value) else { throw invalid() }
    }

    static func text(_ value: String, maximum: Int = 256) throws {
        guard !value.isEmpty, value.utf8.count <= maximum,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw invalid()
        }
    }

    static func windows(_ windows: [QuotaWindow]) throws {
        var ids = Set<String>()
        for window in windows {
            try text(window.id, maximum: 512)
            try text(window.displayLabel)
            if let label = window.providerLabel { try text(label) }
            if let providerID = window.providerID { try text(providerID) }
            guard ids.insert(window.id).inserted else { throw invalid() }
            try percentage(window.usedPercent)
            guard window.remainingPercent.isFinite,
                  (-10_000...100).contains(window.remainingPercent) else { throw invalid() }
            try timestamp(window.observedAt.timeIntervalSince1970)
            if let reset = window.expectedResetsAt { try timestamp(reset.timeIntervalSince1970) }
            if let reset = window.resetObservedAt { try timestamp(reset.timeIntervalSince1970) }
        }
    }

    static func observation(_ observation: ClaudeObservation) throws {
        try timestamp(observation.observedAt.timeIntervalSince1970)
        for limit in [observation.rateLimits.fiveHour, observation.rateLimits.sevenDay, observation.rateLimits.spendLimit].compactMap({ $0 }) {
            try percentage(limit.usedPercentage)
            if let reset = limit.resetsAt { try timestamp(reset) }
        }
    }

    private static func invalid() -> ProcessRunnerError {
        .invalidOutput("Provider returned an invalid quota observation.")
    }
}

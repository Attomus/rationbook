// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Testing
@testable import RationbookCore

@Suite struct CodexParsingTests {
    @Test func prefersLimitIdMap() throws {
        let result = try jsonObject(fixture("codex-multi-bucket"))
        let status = try CodexAdapter.parseRateLimits(result, observedAt: Date(timeIntervalSince1970: 1_788_100_000), version: "0.test")
        #expect(status.account?.plan == "pro")
        #expect(status.windows.count == 3)
        #expect(status.windows.contains { $0.durationSeconds == 18_000 && $0.usedPercent == 32.25 })
        #expect(status.windows.contains { $0.providerID == "reviews" && $0.expectedResetsAt == nil })
        #expect(!status.windows.contains { $0.usedPercent == 99 })
        #expect(status.source.maturity == "experimental")
    }

    @Test func preservesRawPercentages() throws {
        let status = try CodexAdapter.parseRateLimits(jsonObject(fixture("codex-single-bucket")), observedAt: Date())
        #expect(status.windows.first?.usedPercent == 110.5)
        #expect(status.windows.first?.remainingPercent == -10.5)
    }

    @Test func rejectsMissingWindows() {
        #expect(throws: (any Error).self) {
            _ = try CodexAdapter.parseRateLimits(["future": true], observedAt: Date())
        }
    }

    @Test(arguments: [
        -1.0,
        0,
        -Double.greatestFiniteMagnitude,
        1.5,
        Double.infinity,
        -Double.infinity,
        Double.nan,
        Double.greatestFiniteMagnitude,
    ])
    func rejectsInvalidDurations(duration: Double) throws {
        let result: [String: Any] = [
            "rateLimits": [
                "limitId": "codex",
                "primary": ["usedPercent": 25.0, "windowDurationMins": duration],
            ],
        ]
        let status = try CodexAdapter.parseRateLimits(result, observedAt: Date(timeIntervalSince1970: 1_000))
        #expect(status.windows.count == 1)
        #expect(status.windows[0].durationSeconds == nil)
    }

    @Test func rejectsOverflowDuration() throws {
        let result: [String: Any] = [
            "rateLimits": [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 25.0,
                    "windowDurationMins": NSNumber(value: UInt64.max),
                ],
            ],
        ]
        let status = try CodexAdapter.parseRateLimits(result, observedAt: Date(timeIntervalSince1970: 1_000))
        #expect(status.windows.count == 1)
        #expect(status.windows[0].durationSeconds == nil)
    }

    @Test func boundsBucketCount() {
        let buckets = Dictionary(uniqueKeysWithValues: (0..<65).map { index in
            ("bucket-\(index)", [
                "limitId": "limit-\(index)",
                "primary": ["usedPercent": 1.0, "windowDurationMins": 300],
            ] as [String: Any])
        })
        #expect(throws: ProcessRunnerError.self) {
            _ = try CodexAdapter.parseRateLimits(
                ["rateLimitsByLimitId": buckets],
                observedAt: Date(timeIntervalSince1970: 1_000)
            )
        }
    }
}

// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import RationbookCore

@Suite struct ClaudeUsageTests {
    @Test func readsAccountAndModelWindows() throws {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let reading = try ClaudeUsageReader.parse([
            "rate_limits_available": true,
            "rate_limits": [
                "five_hour": NSNull(),
                "seven_day": ["utilization": 40, "resets_at": "2026-11-27T18:59:59.591052+00:00"],
                "seven_day_fable": ["utilization": 30],
                "model_scoped": [["display_name": "Fable", "utilization": 35, "resets_at": "2026-11-27T18:59:59Z"]],
            ],
        ], now: now)
        #expect(reading.observation.rateLimits.fiveHour == nil)
        #expect(reading.observation.rateLimits.sevenDay?.usedPercentage == 40)
        let window = try #require(reading.modelWindows.first)
        #expect(reading.modelWindows.count == 1)
        #expect(window.scope == "model")
        #expect(window.model == "Fable")
        #expect(window.remainingPercent == 65)
        #expect(window.expectedResetsAt != nil)
        #expect(window.observedAt == now)
        let encoded = try RationbookJSON.encoder().encode(reading)
        let decoded = try RationbookJSON.decoder().decode(ClaudeUsageReader.Reading.self, from: encoded)
        #expect(decoded.modelWindows.first?.id == window.id)
    }

    @Test func rejectsMissingAndMalformedUsage() throws {
        for payload: [String: Any] in [
            ["rate_limits_available": false],
            ["rate_limits_available": true, "rate_limits": NSNull()],
            ["rate_limits_available": true, "rate_limits": ["seven_day": ["utilization": true]]],
            ["rate_limits_available": true, "rate_limits": ["seven_day": ["utilization": 20, "resets_at": "tomorrow"]]],
            ["rate_limits_available": true, "rate_limits": ["seven_day": ["utilization": 20], "model_scoped": "invalid"]],
        ] {
            #expect(throws: (any Error).self) { try ClaudeUsageReader.parse(payload, now: Date()) }
        }
    }
    @Test func failedRefreshPreservesReading() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RationbookPaths(root: root)
        let retained = Data("previous observation".utf8)
        try paths.atomicWrite(retained, to: paths.claudeEngineObservation)
        let manager = ClaudeIntegrationManager(paths: paths)
        await #expect(throws: (any Error).self) {
            try await manager.refreshUsage(executable: URL(fileURLWithPath: "/usr/bin/false"), timeout: 1)
        }
        #expect(try Data(contentsOf: paths.claudeEngineObservation) == retained)
        #expect(ProviderRefreshLock(provider: "claude-usage", paths: paths) != nil)
    }

}

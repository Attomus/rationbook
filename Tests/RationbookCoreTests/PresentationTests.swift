// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import RationbookCore

struct PresentationTests {
    private func provider(_ id: String) -> ProviderStatus {
        let current = QuotaWindow(id: "weekly", displayLabel: "Weekly", observedAt: Date(),
                                  freshness: .fresh, usedPercent: 20, dataQuality: .localObserved)
        var historical = current
        historical.id = "retired"
        historical.freshness = .stale
        historical.expectedResetsAt = Date(timeIntervalSince1970: 0)
        if id == "openai" { historical.providerID = "codex_bengalfox" }
        else { historical.scope = "model" }
        return ProviderStatus(provider: id, agentLabel: id, state: .partial,
                              capabilities: AdapterCapabilities(supportsOnDemandRefresh: true, supportsPushUpdates: false,
                                                                supportsAccountScope: true),
                              source: SourceMetadata(name: "fixture", documentation: "documented", maturity: "stable"),
                              windows: [current, historical])
    }

    @Test func currentReadingsWithHistory() {
        var codex = provider("openai")
        codex.errors = [StructuredError(code: "quota_window_absent_after_reset", message: "Retired window")]
        let claude = provider("anthropic")
        for status in [codex, claude] {
            #expect(HumanPresentation.currentState(for: status) == .available)
            #expect(HumanPresentation.historicalWindows(for: status).map(\.id) == ["retired"])
            #expect(status.windows.count == 2)
        }
        #expect(HumanPresentation.overallState(for: [codex, claude]) == .available)
    }

    @Test func currentFailuresRemainVisible() {
        var status = provider("anthropic")
        for (code, expected) in [("refresh_failed", ProviderState.partial),
                                 ("provider_logged_out", .loggedOut),
                                 ("waiting_for_observation", .waitingForObservation)] {
            status.errors = [StructuredError(code: code, message: "Action needed")]
            #expect(HumanPresentation.currentState(for: status) == expected)
            #expect(HumanPresentation.overallState(for: [provider("openai"), status]) == .partial)
        }
    }

    @Test func staleAndMissingReadings() {
        var status = provider("anthropic")
        status.windows[0].freshness = .stale
        #expect(HumanPresentation.currentState(for: status) == .stale)
        #expect(HumanPresentation.overallState(for: [status]) == .stale)
        var fresh = status.windows[0]
        fresh.id = "five-hour"
        fresh.freshness = .fresh
        status.windows.append(fresh)
        #expect(HumanPresentation.currentState(for: status) == .partial)
        #expect(HumanPresentation.overallState(for: []) == .unavailable)
        status.state = .unavailable
        status.windows = []
        #expect(HumanPresentation.currentState(for: status) == .unavailable)
    }
}

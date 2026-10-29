// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Testing
@testable import RationbookCore

@Suite struct CLIContractTests {
    @Test func returnsDocumentedExitCodes() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalid = try runCLI(["status", "--unknown"], dataRoot: root.appendingPathComponent("invalid"))
        #expect(invalid.0 == 64)
        let unattendedClaude = try runCLI(["claude", "refresh"], dataRoot: root.appendingPathComponent("unattended"))
        #expect(unattendedClaude.0 == 70)
        let uninstall = try runCLI(["uninstall"], dataRoot: root.appendingPathComponent("uninstall"))
        #expect(uninstall.0 == 0)
        let forecast = try runCLI(["forecast", "--json"], dataRoot: root.appendingPathComponent("forecast"))
        #expect(forecast.0 == 0)
        #expect(try RationbookJSON.decoder().decode(ForecastEnvelope.self, from: forecast.1).schemaVersion == 1)
        #expect(!String(decoding: forecast.1, as: UTF8.self).contains("overall_state"))
        let history = try runCLI(["history", "--json", "--limit", "1"], dataRoot: root.appendingPathComponent("history"))
        #expect(history.0 == 0)
        let historyEnvelope = try RationbookJSON.decoder().decode(HistoryEnvelope.self, from: history.1)
        #expect(historyEnvelope.schemaVersion == 1)
        #expect(historyEnvelope.samples.isEmpty)
        let diagnostics = try runCLI(["diagnostics", "--json"], dataRoot: root.appendingPathComponent("diagnostics"))
        #expect(diagnostics.0 == 0)
        #expect(try RationbookJSON.decoder().decode(RationbookDiagnosticReport.self, from: diagnostics.1).schemaVersion == 1)
        let version = try runCLI(["version"], dataRoot: root.appendingPathComponent("version"))
        #expect(String(decoding: version.1, as: UTF8.self).contains(RationbookBuild.version))
    }

    @Test func usesStableJSONFormat() throws {
        let envelope = StatusEnvelope(generatedAt: Date(timeIntervalSince1970: 0), providers: [provider(observedAt: Date(timeIntervalSince1970: 0), used: 12)])
        let text = String(decoding: try RationbookJSON.encoder().encode(envelope), as: UTF8.self)
        #expect(text.contains("\"schema_version\":1"))
        #expect(text.contains("1970-01-01T00:00:00Z"))
        #expect(text.contains("\"remaining_percent\":88"))
        let older = Data(#"{"schema_version":1,"generated_at":"1970-01-01T00:00:00Z","overall_state":"unavailable","providers":[]}"#.utf8)
        #expect(try RationbookJSON.decoder().decode(StatusEnvelope.self, from: older).errors.isEmpty)
    }

    @Test func preservesQuotaMetadata() throws {
        let now = Date(timeIntervalSince1970: 30_000)
        var status = provider(observedAt: now, used: 25)
        status.windows[0].providerID = "codex"
        status.limitingWindowID = status.windows[0].id
        let encoded = try RationbookJSON.encoder().encode(status)
        let decoded = try RationbookJSON.decoder().decode(ProviderStatus.self, from: encoded)
        #expect(decoded == status)
        let object = try jsonObject(encoded)
        #expect(object["limiting_window_id"] as? String == status.limitingWindowID)

        let sample = WindowSample(provider: "openai", windowID: status.windows[0].id, usedPercent: 25,
            remainingPercent: 75, firstObservedAt: now, lastObservedAt: now, sampleCount: 1, freshness: .fresh)
        let history = HistoryEnvelope(generatedAt: now, samples: [sample])
        #expect(try RationbookJSON.decoder().decode(HistoryEnvelope.self, from: RationbookJSON.encoder().encode(history)) == history)
        let forecast = ForecastWindow(provider: "openai", windowID: sample.windowID,
            displayLabel: "5 hour", freshness: .fresh, unavailableReason: "insufficient_recent_samples")
        #expect(try RationbookJSON.decoder().decode(ForecastWindow.self, from: RationbookJSON.encoder().encode(forecast)) == forecast)
    }
}

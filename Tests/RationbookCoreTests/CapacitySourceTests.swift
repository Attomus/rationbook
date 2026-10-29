// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Testing
@testable import RationbookCore

@Suite struct CapacitySourceTests {
    @Test func importsModelWindows() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RationbookPaths(root: root)
        let now = Date(timeIntervalSince1970: 1_788_500_000)
        let supplement = ModelCapacitySupplement(
            observedAt: now.addingTimeInterval(-60),
            windows: [
                .init(
                    model: "Fable",
                    displayLabel: "Fable weekly",
                    durationSeconds: 604_800,
                    usedPercent: 22,
                    resetsAt: now.addingTimeInterval(86_400)
                ),
            ]
        )
        let manager = ModelCapacitySupplementManager(paths: paths)
        let imported = try manager.importData(RationbookJSON.encoder().encode(supplement), now: now)
        #expect(imported == supplement)
        #expect(try manager.load(now: now) == supplement)

        let windows = ModelCapacitySupplementManager.quotaWindows(from: supplement, now: now)
        #expect(windows.count == 1)
        #expect(windows[0].id == "anthropic:model:fable:604800")
        #expect(windows[0].scope == "model")
        #expect(windows[0].remainingPercent == 78)
        #expect(windows[0].dataQuality == .localObserved)

        var status = stat()
        #expect(lstat(paths.modelCapacitySupplement.path, &status) == 0)
        #expect(status.st_mode & 0o777 == 0o600)

        try manager.remove()
        #expect(try manager.load(now: now) == nil)
    }

    @Test func rejectsInvalidSupplement() throws {
        let now = Date(timeIntervalSince1970: 1_788_500_000)
        let credentialBearing = Data("""
        {
          "schema_version": 1,
          "provider": "anthropic",
          "observed_at": "2026-09-03T22:26:40Z",
          "windows": [],
          "access_token": "must-not-be-accepted"
        }
        """.utf8)
        #expect(throws: ModelCapacitySupplementError.invalidJSON) {
            try ModelCapacitySupplementManager.decodeAndValidate(credentialBearing, now: now)
        }

        let invalid = ModelCapacitySupplement(
            observedAt: now,
            windows: [
                .init(model: "Fable", displayLabel: "Fable weekly", durationSeconds: 604_800, usedPercent: 101),
            ]
        )
        #expect(throws: ModelCapacitySupplementError.invalidWindow) {
            try ModelCapacitySupplementManager.decodeAndValidate(RationbookJSON.encoder().encode(invalid), now: now)
        }
    }

    @Test func normalisesSourceWindows() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let provenance = SourceMetadata(
            name: "internal_capacity",
            documentation: "private_undocumented",
            maturity: "experimental",
            authentication: "keychain"
        )
        let snapshot = CapacitySourceSnapshot(
            provider: "anthropic",
            agentLabel: "Anthropic",
            observedAt: now,
            provenance: provenance,
            windows: [
                .init(
                    id: "anthropic:account:five_hour",
                    providerID: "claude_account",
                    displayLabel: "5 hour",
                    scope: "account",
                    durationSeconds: 18_000,
                    usedPercent: 20,
                    resetsAt: now.addingTimeInterval(3_600)
                ),
                .init(
                    id: "anthropic:model:fable:seven_day",
                    providerID: "fable",
                    providerLabel: "Fable",
                    displayLabel: "Fable weekly",
                    scope: "model",
                    model: "Fable",
                    durationSeconds: 604_800,
                    usedPercent: 30,
                    resetsAt: now.addingTimeInterval(86_400)
                ),
            ]
        )

        let adapter = CapacitySourceAdapter(source: TestCapacitySource(snapshot: snapshot))
        let status = try adapter.fetch(now: now)
        #expect(status.provider == "anthropic")
        #expect(status.source == provenance)
        #expect(status.capabilities.supportsAccountScope)
        #expect(status.capabilities.supportsModelScope)
        #expect(status.modelSpecificCapacity == "observed")
        #expect(status.windows.map(\.dataQuality) == [.localObserved, .localObserved])
    }

    @Test func rejectsInvalidSource() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let window = CapacitySourceSnapshot.Window(
            id: "window",
            providerID: "provider",
            displayLabel: "weekly",
            scope: "model",
            model: nil,
            durationSeconds: 604_800,
            usedPercent: 10
        )
        let snapshot = CapacitySourceSnapshot(
            provider: "openai",
            agentLabel: "Provider",
            observedAt: now,
            provenance: SourceMetadata(name: "source", documentation: "private", maturity: "experimental"),
            windows: [window]
        )
        #expect(throws: CapacitySourceError.invalidSnapshot) {
            _ = try CapacitySourceAdapter.normalize(snapshot, expectedProvider: "anthropic", now: now)
        }

        var malformed = snapshot
        malformed.provider = "anthropic"
        #expect(throws: CapacitySourceError.invalidSnapshot) {
            _ = try CapacitySourceAdapter.normalize(malformed, expectedProvider: "anthropic", now: now)
        }
    }
}

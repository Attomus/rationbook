// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Testing
@testable import RationbookCore

@Suite struct SQLiteStoreTests {
    @Test func coalescesRepeatedObservations() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(paths: RationbookPaths(root: root))
        let at = Date(timeIntervalSince1970: 1_000)
        try store.save(provider(observedAt: at, used: 10))
        try store.save(provider(observedAt: at, used: 10))
        var history = try store.history()
        #expect(history.count == 1)
        #expect(history[0].sampleCount == 1)
        try store.save(provider(observedAt: at.addingTimeInterval(60), used: 10))
        history = try store.history()
        #expect(history.count == 1)
        #expect(history[0].sampleCount == 2)
        #expect(history[0].lastObservedAt == at.addingTimeInterval(60))
    }

    @Test func retainsSparseWindowSamples() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RationbookPaths(root: root)
        let store = try SQLiteStore(paths: paths)

        for (time, used) in [(1_000.0, 30.0), (1_060.0, 31.0)] {
            try store.save(provider(observedAt: Date(timeIntervalSince1970: time), used: used))
        }
        for offset in 0..<5 {
            var busy = provider(observedAt: Date(timeIntervalSince1970: 2_000 + Double(offset * 60)), used: Double(10 + offset))
            busy.windows[0].id = "openai:codex:weekly"
            busy.windows[0].displayLabel = "7 day"
            try store.save(busy)
        }

        #expect(try store.history(limit: 5).allSatisfy { $0.windowID == "openai:codex:weekly" })

        let service = try RationbookService(paths: paths)
        let sparse = try service.history(provider: "openai", windowID: "openai:codex:300", limit: 120)
        #expect(sparse.count == 2)
        #expect(sparse.map(\.remainingPercent).sorted() == [69, 70])
    }

    @Test func supportsConcurrentPeers() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RationbookPaths(root: root)
        let writer = try SQLiteStore(paths: paths)
        let reader = try SQLiteStore(paths: paths)
        try writer.save(provider(observedAt: Date(timeIntervalSince1970: 1_000), used: 10))
        #expect(try reader.latestProvider("openai")?.windows.first?.usedPercent == 10)
        try writer.save(provider(observedAt: Date(timeIntervalSince1970: 1_100), used: 11))
        #expect(try reader.latestProvider("openai")?.windows.first?.usedPercent == 11)
    }

    @Test func savesSettingsAndPrunesDaily() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(paths: RationbookPaths(root: root))
        let settings = ReserveSettings(codexShort: 7, codexLong: 12, claudeShort: 3, claudeLong: 8)
        try store.set(settings, forKey: "reserve_settings")
        #expect(try store.value(forKey: "reserve_settings", as: ReserveSettings.self) == settings)
        let now = Date(timeIntervalSince1970: 200_000)
        #expect(try store.pruneIfNeeded(retentionDays: 60, now: now))
        #expect(try !store.pruneIfNeeded(retentionDays: 60, now: now.addingTimeInterval(3_600)))
        #expect(try store.pruneIfNeeded(retentionDays: 60, now: now.addingTimeInterval(90_000)))
    }

    @Test func appliesShorterRetention() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try RationbookService(paths: RationbookPaths(root: root))
        let now = Date(timeIntervalSince1970: 20_000_000)
        try service.updateRetentionDays(0, now: now)
        try service.store.save(provider(observedAt: now.addingTimeInterval(-3 * 86_400), used: 10))
        _ = service.status(now: now)
        #expect(try service.history().count == 1)
        try service.updateRetentionDays(2, now: now.addingTimeInterval(60))
        #expect(try service.history().isEmpty)
        try service.store.save(provider(observedAt: now.addingTimeInterval(-86_400), used: 20))
        _ = service.status(now: now.addingTimeInterval(3_600))
        #expect(try service.history().count == 1)
        _ = service.status(now: now.addingTimeInterval(2 * 86_400))
        #expect(try service.history().isEmpty)
    }

    @Test func preservesInaccessibleDatabase() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RationbookPaths(root: root)
        try paths.prepare()
        try FileManager.default.createDirectory(at: paths.database, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { _ = try RationbookService(paths: paths) }
        #expect(FileManager.default.fileExists(atPath: paths.database.path))
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.contains(".damaged-") })
    }

    @Test func preservesUnsupportedDatabase() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RationbookPaths(root: root)
        try paths.prepare()
        _ = try ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: [paths.database.path, "CREATE TABLE schema_meta(version INTEGER NOT NULL); INSERT INTO schema_meta VALUES(99);"]
        )
        #expect(throws: SQLiteStoreError.self) { _ = try RationbookService(paths: paths) }
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.contains(".damaged-") })

        let otherRoot = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        let otherPaths = RationbookPaths(root: otherRoot)
        let held = try #require(ProviderRefreshLock(provider: "database-migration", paths: otherPaths))
        do {
            _ = try SQLiteStore(paths: otherPaths)
            Issue.record("Expected migration lock contention")
        } catch SQLiteStoreError.migrationLocked {
            // Expected: migration contention is distinct from corruption.
        }
        withExtendedLifetime(held) {}
    }

    @Test func recoversDamagedDatabase() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RationbookPaths(root: root)
        try paths.prepare()
        try Data("not a sqlite database".utf8).writePrivateFixture(to: paths.database)
        let service = try RationbookService(paths: paths)
        #expect(service.startupErrors.first?.code == "database_rebuilt")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(names.contains { $0.hasPrefix("rationbook.sqlite3.damaged-") })
        #expect(FileManager.default.fileExists(atPath: paths.database.path))
    }
}

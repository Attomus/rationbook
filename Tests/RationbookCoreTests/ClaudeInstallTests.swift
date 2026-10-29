// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Testing
@testable import RationbookCore

@Suite struct ClaudeInstallTests {
    @Test func restoresPreviousStatusLine() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let original = Data(#"{"theme":"dark","statusLine":{"type":"command","command":"/usr/bin/printf prior"}}"#.utf8)
        try original.writePrivateFixture(to: settings)
        let manager = ClaudeIntegrationManager(paths: RationbookPaths(root: root.appendingPathComponent("rationbook")), settingsURL: settings)
        let first = try manager.install(helperSource: URL(fileURLWithPath: "/bin/echo"))
        let second = try manager.install(helperSource: URL(fileURLWithPath: "/bin/echo"))
        #expect(first == second)
        try manager.uninstall()
        let restored = try jsonObject(Data(contentsOf: settings))
        let statusLine = try #require(restored["statusLine"] as? [String: Any])
        #expect(statusLine["command"] as? String == "/usr/bin/printf prior")
        #expect(restored["theme"] as? String == "dark")
    }

    @Test func refreshUpgradesInstalledHelper() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RationbookPaths(root: root.appendingPathComponent("support"))
        let settings = root.appendingPathComponent("settings.json")
        let manager = ClaudeIntegrationManager(paths: paths, settingsURL: settings)
        #expect(throws: ClaudeIntegrationError.notInstalled) {
            _ = try manager.prepareUsageCommand(helperSource: URL(fileURLWithPath: "/bin/cat"))
        }
        let old = try manager.install(helperSource: URL(fileURLWithPath: "/bin/echo"))
        let originalSettings = try Data(contentsOf: settings)
        _ = try manager.prepareUsageCommand(helperSource: URL(fileURLWithPath: "/bin/cat"))
        let installed = try Data(contentsOf: URL(fileURLWithPath: old.helperPath))
        #expect(installed == (try Data(contentsOf: URL(fileURLWithPath: "/bin/cat"))))
        #expect(try Data(contentsOf: settings) == originalSettings)
        _ = try manager.prepareUsageCommand()
        let loginCommand = try manager.prepareUsageCommand(signIn: true)
        #expect(try String(contentsOf: loginCommand, encoding: .utf8).contains(" --login"))
        #expect(try Data(contentsOf: settings) == originalSettings)
        try manager.uninstall()
    }

    @Test func preservesEditedSettings() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("{}".utf8).writePrivateFixture(to: settings)
        let manager = ClaudeIntegrationManager(paths: RationbookPaths(root: root.appendingPathComponent("rationbook")), settingsURL: settings)
        _ = try manager.install(helperSource: URL(fileURLWithPath: "/bin/echo"))
        try Data(#"{"statusLine":{"type":"command","command":"user-new-command"}}"#.utf8).writePrivateFixture(to: settings)
        #expect(throws: ClaudeIntegrationError.settingsChanged) { try manager.uninstall() }
    }

    @Test func rejectsSettingsSymlink() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real.json")
        let link = root.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let manager = ClaudeIntegrationManager(paths: RationbookPaths(root: root.appendingPathComponent("rationbook")), settingsURL: link)
        #expect(throws: ClaudeIntegrationError.unsafeSettingsPath) {
            _ = try manager.install(helperSource: URL(fileURLWithPath: "/bin/echo"))
        }
    }

    @Test func rejectsUnsafeInstallTargets() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let realParent = root.appendingPathComponent("real", isDirectory: true)
        let linkedParent = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: realParent)
        let unsafeManager = ClaudeIntegrationManager(paths: RationbookPaths(root: root.appendingPathComponent("unsafe-support")), settingsURL: linkedParent.appendingPathComponent("settings.json"))
        #expect(throws: ClaudeIntegrationError.unsafeSettingsPath) { _ = try unsafeManager.install(helperSource: URL(fileURLWithPath: "/bin/echo")) }

        let settings = root.appendingPathComponent("claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("{}".utf8).writePrivateFixture(to: settings)
        let paths = RationbookPaths(root: root.appendingPathComponent("support"))
        let manager = ClaudeIntegrationManager(paths: paths, settingsURL: settings)
        let record = try manager.install(helperSource: URL(fileURLWithPath: "/bin/echo"))
        try Data("tampered".utf8).write(to: URL(fileURLWithPath: record.helperPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: record.helperPath)
        #expect(throws: ClaudeIntegrationError.helperChanged) { _ = try manager.install(helperSource: URL(fileURLWithPath: "/bin/echo")) }
        #expect(throws: ClaudeIntegrationError.helperChanged) { try manager.uninstall() }
    }

    @Test func confinesInstallPaths() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("{}".utf8).writePrivateFixture(to: settings)
        let paths = RationbookPaths(root: root.appendingPathComponent("support"))
        try paths.prepare()
        let foreignHelper = paths.binDirectory.appendingPathComponent("rationbook-claude-helper")
        try Data("foreign".utf8).write(to: foreignHelper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: foreignHelper.path)
        let manager = ClaudeIntegrationManager(paths: paths, settingsURL: settings)
        #expect(throws: ClaudeIntegrationError.helperChanged) { _ = try manager.install(helperSource: URL(fileURLWithPath: "/bin/echo")) }
        #expect(try String(contentsOf: foreignHelper, encoding: .utf8) == "foreign")
    }

    @Test func doesNotCopyWholeSettings() throws {
        let outer = try hardeningTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: outer) }
        let settings = outer.appendingPathComponent("claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(#"{"theme":"dark"}"#.utf8).writePrivateFixture(to: settings)
        let paths = RationbookPaths(root: outer.appendingPathComponent("data"))
        let manager = ClaudeIntegrationManager(paths: paths, settingsURL: settings)
        _ = try manager.install(helperSource: URL(fileURLWithPath: "/bin/echo"))
        let generated = try FileManager.default.contentsOfDirectory(atPath: paths.root.path)
            .filter { $0.hasPrefix("claude-settings-") }
        #expect(generated.isEmpty)

        try manager.uninstall()
    }

    @Test func recoversPartialInstall() throws {
        let boundaries: [ClaudeInstallBoundary] = [
            .pendingRecordWritten,
            .helperWritten,
            .settingsWritten,
            .ownershipRecordWritten,
        ]
        for boundary in boundaries {
            let outer = try hardeningTemporaryRoot("claude-\(boundary)")
            defer { try? FileManager.default.removeItem(at: outer) }
            let settingsURL = outer.appendingPathComponent("claude/settings.json")
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(#"{"theme":"dark","statusLine":{"type":"command","command":"/bin/previous"}}"#.utf8).writePrivateFixture(to: settingsURL)
            let paths = RationbookPaths(root: outer.appendingPathComponent("data"))
            var interrupted = ClaudeIntegrationManager(paths: paths, settingsURL: settingsURL)
            interrupted.installFailureInjector = { reached in
                if reached == boundary { throw InjectedInstallFailure.stop }
            }
            #expect(throws: InjectedInstallFailure.stop) {
                _ = try interrupted.install(helperSource: URL(fileURLWithPath: "/bin/echo"))
            }
            #expect(FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("claude-integration.pending.json").path))

            let recovery = ClaudeIntegrationManager(paths: paths, settingsURL: settingsURL)
            if boundary == .pendingRecordWritten {
                #expect(throws: ClaudeIntegrationError.notInstalled) { try recovery.uninstall() }
            } else {
                try recovery.uninstall()
            }
            #expect(!FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("claude-integration.pending.json").path))
            let restored = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
            let statusLine = try #require(restored["statusLine"] as? [String: Any])
            #expect(statusLine["command"] as? String == "/bin/previous")
            #expect(restored["theme"] as? String == "dark")
            #expect(!FileManager.default.fileExists(atPath: paths.binDirectory.appendingPathComponent("rationbook-claude-helper").path))
        }
    }

    @Test func serialisesConcurrentInstalls() throws {
        let outer = try hardeningTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: outer) }
        let settings = outer.appendingPathComponent("claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("{}".utf8).writePrivateFixture(to: settings)
        let paths = RationbookPaths(root: outer.appendingPathComponent("data"))
        let manager = ClaudeIntegrationManager(paths: paths, settingsURL: settings)
        let results = InstallResults()
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            do {
                _ = try manager.install(helperSource: URL(fileURLWithPath: "/bin/echo"))
                results.lock.withLock { results.successes += 1 }
            } catch {
                results.lock.withLock { results.failures.append(error) }
            }
        }
        #expect(results.successes == 4)
        #expect(results.failures.isEmpty)
        try paths.validateFileForRead(paths.claudeIntegration)
        let record = try RationbookJSON.decoder().decode(ClaudeIntegrationRecord.self, from: Data(contentsOf: paths.claudeIntegration))
        #expect(record.canonicalRootPath == paths.root.path)
        #expect(FileManager.default.fileExists(atPath: record.helperPath))
    }
}

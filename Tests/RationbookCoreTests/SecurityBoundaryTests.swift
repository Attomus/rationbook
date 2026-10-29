// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Testing
@testable import RationbookCore

@Suite struct SecurityBoundaryTests {
    @Test func rejectsMutableInstallParents() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: shared.path)
        let data = shared.appendingPathComponent("data")
        #expect(throws: RationbookPathError.self) { try RationbookPaths(root: data).prepare() }
        #expect(!FileManager.default.fileExists(atPath: data.path))
        let manager = CLIIntegrationManager(paths: RationbookPaths(root: root.appendingPathComponent("safe")), localBin: shared)
        #expect(throws: RationbookPathError.self) { try manager.install(source: URL(fileURLWithPath: "/bin/echo")) }
        #expect(!FileManager.default.fileExists(atPath: shared.appendingPathComponent("rationbook").path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shared.path)
        _ = try manager.install(source: URL(fileURLWithPath: "/bin/echo"))
        try FileManager.default.setAttributes([.posixPermissions: 0o770], ofItemAtPath: shared.path)
        #expect(throws: RationbookPathError.self) { try manager.uninstall() }
        #expect(FileManager.default.fileExists(atPath: shared.appendingPathComponent("rationbook").path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shared.path)
        try manager.uninstall()
    }

    @Test func rejectsStickyCLIDestination() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RationbookPaths(root: root.appendingPathComponent("data"))
        let manager = CLIIntegrationManager(paths: paths, localBin: URL(fileURLWithPath: "/private/tmp"))
        #expect(throws: RationbookPathError.self) { try manager.install(source: URL(fileURLWithPath: "/bin/echo")) }
        #expect(throws: RationbookPathError.self) { try manager.uninstall() }
        #expect(!FileManager.default.fileExists(atPath: paths.cliIntegration.path))
    }

    @Test func skipsACLCandidate() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let unsafe = root.appendingPathComponent(".local/bin")
        let safe = root.appendingPathComponent("safe")
        for directory in [unsafe, safe] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: directory.appendingPathComponent("codex"))
        }
        try setACL("everyone allow write", on: unsafe.appendingPathComponent("codex"))
        let located = try ExecutableLocator.locate("codex", environment: ["PATH": unsafe.path], homeDirectory: root,
                                                  currentDirectory: URL(fileURLWithPath: "/"), standardDirectories: [safe])
        #expect(located.resolvingSymlinksInPath() == safe.appendingPathComponent("codex").resolvingSymlinksInPath())
        let failure = #expect(throws: ProcessRunnerError.self) {
            try ExecutableLocator.locate("codex", environment: ["PATH": unsafe.path], homeDirectory: root,
                                         currentDirectory: URL(fileURLWithPath: "/"), standardDirectories: [])
        }
        if case .unsafeExecutable = failure {} else { Issue.record("Expected unsafe executable classification") }
    }

    @Test func rejectsSymlinkedCLIDirectory() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let manager = CLIIntegrationManager(paths: RationbookPaths(root: root.appendingPathComponent("data")), localBin: link)
        #expect(throws: RationbookPathError.self) { try manager.install(source: URL(fileURLWithPath: "/bin/echo")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func rejectsACLMutationGrants() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("provider")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try setACL("everyone allow write", on: executable)
        #expect(throws: RationbookPathError.self) { try FileTrust.rejectMutationACL(executable) }
        #expect(throws: (any Error).self) { try ExecutableLocator.prepareForLaunch(executable) }
        try setACL("everyone allow delete_child", on: root)
        #expect(throws: RationbookPathError.self) { try RationbookPaths(root: root.appendingPathComponent("data")).prepare() }
    }

    @Test func validatesEachCreatedDirectory() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("new/parent/data")
        try RationbookPaths(root: nested).prepare()
        try FileTrust.validateDirectoryChain(nested)
        let unsafe = root.appendingPathComponent("unsafe")
        try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: false)
        try setACL("everyone allow delete_child", on: unsafe)
        let child = unsafe.appendingPathComponent("missing/data")
        #expect(throws: RationbookPathError.self) { try FileTrust.createDirectory(child) }
        #expect(!FileManager.default.fileExists(atPath: unsafe.appendingPathComponent("missing").path))
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: nested)
        #expect(throws: RationbookPathError.self) { try FileTrust.createDirectory(link.appendingPathComponent("child")) }
        #expect(!FileManager.default.fileExists(atPath: nested.appendingPathComponent("child").path))
    }

    @Test func protectsClaudeSettingsAncestryAndACLs() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("settings-parent")
        let settings = parent.appendingPathComponent("claude/settings.json")
        let manager = ClaudeIntegrationManager(paths: RationbookPaths(root: root.appendingPathComponent("data")), settingsURL: settings)
        _ = try manager.install(helperSource: URL(fileURLWithPath: "/bin/echo"))
        let installed = try Data(contentsOf: settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: parent.path)
        #expect(throws: ClaudeIntegrationError.unsafeSettingsPath) { try manager.uninstall() }
        #expect(try Data(contentsOf: settings) == installed)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        try setACL("everyone allow write", on: settings)
        #expect(throws: ClaudeIntegrationError.unsafeSettingsPath) { try manager.uninstall() }
        #expect(try Data(contentsOf: settings) == installed)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["-N", settings.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        try manager.uninstall()
    }

    @Test func rejectsMalformedQuotaScalars() throws {
        let now = Date()
        for value: Any in [true, Double.greatestFiniteMagnitude, -1.0] {
            let codex: [String: Any] = ["rateLimits": ["limitId": "test", "primary": ["usedPercent": value]]]
            #expect(throws: ProcessRunnerError.self) { try CodexAdapter.parseRateLimits(codex, observedAt: now) }
            let claude: [String: Any] = ["rate_limits": ["five_hour": ["used_percentage": value]]]
            let data = try JSONSerialization.data(withJSONObject: claude)
            #expect(throws: ProcessRunnerError.self) { try ClaudeAdapter.observation(fromStatusLine: data) }
        }
        let invalidReset: [String: Any] = ["rateLimits": ["primary": ["usedPercent": 1, "resetsAt": true]]]
        #expect(throws: ProcessRunnerError.self) { try CodexAdapter.parseRateLimits(invalidReset, observedAt: now) }
        let bucket: [String: Any] = ["limitId": "same", "primary": ["usedPercent": 1]]
        #expect(throws: ProcessRunnerError.self) {
            try CodexAdapter.parseRateLimits(["rateLimitsByLimitId": ["a": bucket, "b": bucket]], observedAt: now)
        }
    }

    @Test func preservesHistoryAfterBadInput() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(paths: RationbookPaths(root: root))
        let good = try CodexAdapter.parseRateLimits(jsonObject(fixture("codex-single-bucket")), observedAt: Date())
        try store.save(good)
        var bad = good
        bad.windows[0].usedPercent = Double.greatestFiniteMagnitude
        #expect(throws: ProcessRunnerError.self) { try store.save(bad) }
        #expect(try store.latestProvider("openai")?.windows[0].usedPercent == 110.5)
        #expect(try store.history().allSatisfy { $0.usedPercent.isFinite })
    }

    private func setACL(_ entry: String, on url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", entry, url.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}

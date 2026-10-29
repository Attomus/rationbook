// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Testing
@testable import RationbookCore

@Suite struct ClaudeFeedTests {
    @Test func storesOnlyQuotaFields() throws {
        let observation = try ClaudeAdapter.observation(fromStatusLine: fixture("claude-both"), observedAt: Date(timeIntervalSince1970: 100))
        #expect(observation.claudeVersion == "2.1.251-synthetic")
        #expect(observation.rateLimits.fiveHour?.usedPercentage == 21.5)
        #expect(observation.rateLimits.spendLimit?.usedPercentage == 120)
        let text = String(decoding: try RationbookJSON.encoder().encode(observation), as: UTF8.self)
        #expect(!text.contains("workspace"))
        #expect(!text.contains("session"))
        #expect(!text.contains("transcript"))
    }

    @Test func rejectsInvalidInput() {
        #expect(throws: (any Error).self) {
            _ = try ClaudeAdapter.observation(fromStatusLine: Data("not-json".utf8))
        }
        #expect(throws: (any Error).self) {
            _ = try ClaudeAdapter.observation(fromStatusLine: Data(repeating: 0x20, count: 1_048_577))
        }
    }

    @Test func keepsAggregateWindowsSeparate() throws {
        let observation = try ClaudeAdapter.observation(fromStatusLine: fixture("claude-five-hour-only"), observedAt: Date(timeIntervalSince1970: 100))
        let status = ClaudeAdapter.normalize(observation, now: Date(timeIntervalSince1970: 200))
        #expect(status.windows.count == 1)
        #expect(status.windows[0].scope == "account")
        #expect(status.windows[0].model == nil)
        #expect(status.windows[0].expectedResetsAt == nil)
        #expect(status.capabilities.supportsModelScope == false)
    }

    @Test func waitsForQuotaData() throws {
        let observation = try ClaudeAdapter.observation(fromStatusLine: fixture("claude-no-limits"))
        let status = ClaudeAdapter.normalize(observation)
        #expect(status.state == .waitingForObservation)
        #expect(status.windows.isEmpty)
        #expect(status.errors.first?.code == "quota_fields_absent")
    }

    @Test func forwardsOriginalInput() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RationbookPaths(root: root)
        try paths.prepare()
        let helperData = try Data(contentsOf: builtProduct("rationbook-claude-helper"))
        let helper = paths.binDirectory.appendingPathComponent("rationbook-claude-helper")
        try paths.atomicWrite(helperData, to: helper, permissions: 0o700)
        let previous = try JSONSerialization.data(withJSONObject: ["type": "command", "command": "/bin/cat"], options: [.sortedKeys])
        let installed = try JSONSerialization.data(withJSONObject: ["type": "command", "command": "'\(helper.path)' --data-root '\(root.path)'"], options: [.sortedKeys])
        let record = ClaudeIntegrationRecord(
            schemaVersion: 3, installedAt: Date(timeIntervalSince1970: 0), helperPath: helper.path,
            settingsPath: "/synthetic/settings.json", previousStatusLine: previous,
            installedStatusLine: installed, helperSha256: FileDigest.sha256(helperData), canonicalRootPath: paths.root.path
        )
        try paths.atomicWrite(try RationbookJSON.encoder().encode(record), to: paths.claudeIntegration)

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = helper
        process.arguments = ["--data-root", paths.root.path]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        var environment = ProcessInfo.processInfo.environment
        environment["RATIONBOOK_DATA_DIR"] = root.path
        process.environment = environment
        let input = try fixture("claude-both")
        try process.run()
        try inputPipe.fileHandleForWriting.write(contentsOf: input)
        try inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(outputPipe.fileHandleForReading.readDataToEndOfFile() == input)
        let persisted = try Data(contentsOf: paths.claudeObservation)
        let persistedText = String(decoding: persisted, as: UTF8.self)
        #expect(!persistedText.contains("session_id"))
        #expect(!persistedText.contains("transcript_path"))
        #expect(!persistedText.contains("workspace"))
    }

    @Test func forwardsOversizedInput() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RationbookPaths(root: root)
        try paths.prepare()
        let helperData = try Data(contentsOf: builtProduct("rationbook-claude-helper"))
        let helper = paths.binDirectory.appendingPathComponent("rationbook-claude-helper")
        try paths.atomicWrite(helperData, to: helper, permissions: 0o700)
        let previous = try JSONSerialization.data(withJSONObject: ["type": "command", "command": "/bin/cat"], options: [.sortedKeys])
        let installed = try JSONSerialization.data(withJSONObject: ["type": "command", "command": "'\(helper.path)' --data-root '\(root.path)'"], options: [.sortedKeys])
        let record = ClaudeIntegrationRecord(schemaVersion: 3, installedAt: Date(), helperPath: helper.path, settingsPath: "/synthetic/settings.json", previousStatusLine: previous, installedStatusLine: installed, helperSha256: FileDigest.sha256(helperData), canonicalRootPath: paths.root.path)
        try paths.atomicWrite(try RationbookJSON.encoder().encode(record), to: paths.claudeIntegration)

        let outputURL = root.appendingPathComponent("forwarded")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let process = Process()
        let inputPipe = Pipe()
        process.executableURL = helper
        process.arguments = ["--data-root", paths.root.path]
        process.standardInput = inputPipe
        process.standardOutput = output
        var environment = ProcessInfo.processInfo.environment
        environment["RATIONBOOK_DATA_DIR"] = root.path
        process.environment = environment
        let input = Data(repeating: 0x61, count: 1_200_000)
        try process.run()
        try inputPipe.fileHandleForWriting.write(contentsOf: input)
        try inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        try output.close()
        #expect(try Data(contentsOf: outputURL) == input)
        #expect(!FileManager.default.fileExists(atPath: paths.claudeObservation.path))
    }

    @Test func ignoresEmptyAndRepeatedEvents() throws {
        var payload = try #require(JSONSerialization.jsonObject(with: fixture("claude-both")) as? [String: Any])
        payload["session_id"] = "synthetic-session"
        payload["cost"] = ["total_api_duration_ms": 100]
        let initial = try ClaudeAdapter.observation(fromStatusLine: JSONSerialization.data(withJSONObject: payload), observedAt: Date(timeIntervalSince1970: 100))
        let replay = try ClaudeAdapter.observation(fromStatusLine: JSONSerialization.data(withJSONObject: payload), observedAt: Date(timeIntervalSince1970: 200))
        #expect(initial.shouldReplace(nil))
        #expect(!replay.shouldReplace(initial))
        let empty = try ClaudeAdapter.observation(fromStatusLine: fixture("claude-no-limits"))
        #expect(!empty.shouldReplace(initial))
        payload["cost"] = ["total_api_duration_ms": 200]
        let afterResponse = try ClaudeAdapter.observation(fromStatusLine: JSONSerialization.data(withJSONObject: payload))
        #expect(afterResponse.shouldReplace(initial))
        let encoded = String(decoding: try RationbookJSON.encoder().encode(initial), as: UTF8.self)
        #expect(!encoded.contains("synthetic-session"))
    }

    @Test func preservesNewerSessionReading() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RationbookPaths(root: root)
        var payload = try #require(JSONSerialization.jsonObject(with: fixture("claude-both")) as? [String: Any])
        payload["session_id"] = "session-a"
        let a = try ClaudeAdapter.observation(fromStatusLine: JSONSerialization.data(withJSONObject: payload), observedAt: Date(timeIntervalSince1970: 100))
        try ClaudeAdapter.persist(a, paths: paths)
        payload["session_id"] = "session-b"
        var b = try ClaudeAdapter.observation(fromStatusLine: JSONSerialization.data(withJSONObject: payload), observedAt: Date(timeIntervalSince1970: 200))
        b.rateLimits.fiveHour?.usedPercentage = 25
        try ClaudeAdapter.persist(b, paths: paths)
        var replay = a
        replay.observedAt = Date(timeIntervalSince1970: 300)
        try ClaudeAdapter.persist(replay, paths: paths)
        var replayB = b
        replayB.observedAt = Date(timeIntervalSince1970: 400)
        try ClaudeAdapter.persist(replayB, paths: paths)
        let retained = try RationbookJSON.decoder().decode(ClaudeObservation.self, from: Data(contentsOf: paths.claudeObservation))
        #expect(retained == b)
    }

    @Test func repairsCorruptObservation() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RationbookPaths(root: root)
        try paths.prepare()
        try paths.atomicWrite(Data("invalid cache".utf8), to: paths.claudeObservation)
        let observation = ClaudeObservation(observedAt: Date(timeIntervalSince1970: 10_000), claudeVersion: "test",
            rateLimits: .init(fiveHour: .init(usedPercentage: 10, resetsAt: nil)), sourceRevision: "new", sourceKey: "session")
        try ClaudeAdapter.persist(observation, paths: paths)
        let saved = try RationbookJSON.decoder().decode(ClaudeObservation.self, from: Data(contentsOf: paths.claudeObservation))
        #expect(saved == observation)
    }

    @Test func bindsHelperToInstalledRoot() throws {
        let outer = try hardeningTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: outer) }
        let first = RationbookPaths(root: outer.appendingPathComponent("first"))
        let second = RationbookPaths(root: outer.appendingPathComponent("second"))
        let helper = try installTestHelper(at: first)
        try second.prepare()

        // A forged manifest in a second root cannot authorize the helper installed
        // under the first root, even when all fields and the digest are plausible.
        let forged = try Data(contentsOf: first.claudeIntegration)
        var record = try RationbookJSON.decoder().decode(ClaudeIntegrationRecord.self, from: forged)
        record.canonicalRootPath = second.root.path
        try second.atomicWrite(try RationbookJSON.encoder().encode(record), to: second.claudeIntegration)
        let drifted = try runTestHelper(helper, root: second.root)
        #expect(drifted.0 == 0)
        #expect(!FileManager.default.fileExists(atPath: second.claudeObservation.path))
        #expect(!FileManager.default.fileExists(atPath: first.claudeObservation.path))

        // The explicit, installed root wins over an unrelated inherited value and
        // still authenticates the manifest before forwarding.
        let bound = try runTestHelper(helper, root: first.root, inheritedRoot: second.root)
        #expect(bound.0 == 0)
        #expect(FileManager.default.fileExists(atPath: first.claudeObservation.path))
        #expect(!FileManager.default.fileExists(atPath: second.claudeObservation.path))
    }

    @Test func receivesFeedAndUnlocks() async throws {
        let root = try hardeningTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RationbookPaths(root: root.appendingPathComponent("data"))
        let source = root.appendingPathComponent("helper")
        let observation = ClaudeObservation(observedAt: Date().addingTimeInterval(1), claudeVersion: "test",
            rateLimits: .init(fiveHour: .init(usedPercentage: 20, resetsAt: nil)))
        let fixture = root.appendingPathComponent("observation.json")
        var encoded = try JSONSerialization.jsonObject(with: RationbookJSON.encoder().encode(observation)) as! [String: Any]
        encoded["source_key"] = "SOURCE_KEY"
        try JSONSerialization.data(withJSONObject: encoded).write(to: fixture)
        let script = """
        #!/bin/sh
        cp '\(fixture.path)' "$2/claude-observation.json"
        sleep 0.4
        key=$(printf '%s' "$4" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
        /usr/bin/sed "s/SOURCE_KEY/$key/" '\(fixture.path)' > "$2/next.json"
        /bin/mv "$2/next.json" "$2/claude-observation.json"
        exec sleep 60
        """
        try Data(script.utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
        let manager = ClaudeIntegrationManager(paths: paths, settingsURL: root.appendingPathComponent("settings.json"))
        _ = try manager.install(helperSource: source)
        try paths.atomicWrite(Data("invalid cache".utf8), to: paths.claudeObservation)
        let started = Date()
        try await manager.refreshUsageAutomatically()
        #expect(Date().timeIntervalSince(started) >= 0.4)
        #expect(ProviderRefreshLock(provider: "claude-usage", paths: paths) != nil)
        let actual = try RationbookJSON.decoder().decode(ClaudeObservation.self, from: Data(contentsOf: paths.claudeObservation))
        #expect(actual.rateLimits == observation.rateLimits)
    }

    @Test func cancelsOwnedSession() async throws {
        let root = try hardeningTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RationbookPaths(root: root.appendingPathComponent("data"))
        let source = root.appendingPathComponent("helper")
        let pidFile = root.appendingPathComponent("child.pid")
        try Data("#!/bin/sh\necho $$ > '\(pidFile.path).tmp'\nmv '\(pidFile.path).tmp' '\(pidFile.path)'\nexec sleep 60\n".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
        let manager = ClaudeIntegrationManager(paths: paths, settingsURL: root.appendingPathComponent("settings.json"))
        _ = try manager.install(helperSource: source)
        let task = Task { try await manager.refreshUsageAutomatically() }
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: pidFile.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do { try await task.value; Issue.record("Cancelled refresh unexpectedly succeeded") }
        catch is CancellationError {}
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(ProviderRefreshLock(provider: "claude-usage", paths: paths) != nil)
    }

    @Test(arguments: ["/usr/bin/true", "echo hi"])
    func savesQuotaAfterInputCloses(_ command: String) throws {
        let outer = try hardeningTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: outer) }
        let paths = RationbookPaths(root: outer.appendingPathComponent("data"))
        let helper = try installTestHelper(at: paths, previousCommand: "exec 0<&-; \(command); /usr/bin/touch '\(outer.path)/closed'")
        let process = Process()
        let input = Pipe()
        process.executableURL = helper
        process.arguments = ["--data-root", paths.root.path]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: outer.appendingPathComponent("closed").path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(FileManager.default.fileExists(atPath: outer.appendingPathComponent("closed").path))
        try input.fileHandleForWriting.write(contentsOf: Data(#"{"version":"test","rate_limits":{"five_hour":{"used_percentage":5}}}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let observation = try RationbookJSON.decoder().decode(ClaudeObservation.self, from: Data(contentsOf: paths.claudeObservation))
        #expect(observation.rateLimits.fiveHour?.usedPercentage == 5)
    }
}

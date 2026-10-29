// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Testing
@testable import RationbookCore

@Suite struct ProcessTests {
    @Test func readsExpectedFailureStatus() throws {
        let arguments = ["-c", "printf '{\"loggedIn\":false}'; exit 1"]
        let shell = URL(fileURLWithPath: "/bin/sh")
        #expect(throws: ProcessRunnerError.self) {
            _ = try ProcessRunner.run(executable: shell, arguments: arguments)
        }
        let output = try ProcessRunner.run(executable: shell, arguments: arguments, acceptedExitCodes: [0, 1])
        #expect(output.exitCode == 1)
        #expect(String(decoding: output.stdout, as: UTF8.self) == #"{"loggedIn":false}"#)
    }

    @Test func boundsOutputAndRuntime() {
        #expect(throws: (any Error).self) {
            _ = try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: [String(repeating: "x", count: 100)], maxOutputBytes: 10)
        }
        #expect(throws: ProcessRunnerError.self) {
            _ = try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["1"], timeout: 0.01)
        }
    }

    @Test func killsUnresponsiveChild() {
        let started = Date()
        #expect(throws: ProcessRunnerError.self) {
            _ = try ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; while :; do sleep 1; done"],
                timeout: 0.05
            )
        }
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func terminatesChildGroup() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("child-pid")
        #expect(throws: ProcessRunnerError.self) {
            _ = try ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; sleep 60 & echo $! > \"$0.tmp\"; mv \"$0.tmp\" \"$0\"; wait", pidFile.path],
                timeout: 0.1
            )
        }
        let childPID = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(!processIsLive(childPID))
    }

    @Test func cleansOrphanedChildren() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("orphan-pid")
        let started = Date()
        let output = try ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 60 & echo $! > \"$0\"", pidFile.path],
            timeout: 2
        )
        #expect(output.exitCode == 0)
        #expect(Date().timeIntervalSince(started) < 2)
        let childPID = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(!processIsLive(childPID))
    }

    @Test func reportsClosedInput() throws {
        let process = try ManagedChildProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec 0<&-; printf r; sleep 1"]
        )
        #expect(try process.standardOutput.read(upToCount: 1) == Data("r".utf8))
        let bytes = Array("closed-input".utf8)
        let result = bytes.withUnsafeBytes { buffer in
            Darwin.write(process.standardInput.fileDescriptor, buffer.baseAddress, buffer.count)
        }
        #expect(result == -1)
        #expect(errno == EPIPE)
        #expect(process.wait(timeout: 2))
        process.terminateAndReap()
    }

    @Test func locksProvidersIndependently() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RationbookPaths(root: root)
        let first = try #require(ProviderRefreshLock(provider: "openai", paths: paths))
        #expect(ProviderRefreshLock(provider: "openai", paths: paths) == nil)
        #expect(ProviderRefreshLock(provider: "anthropic", paths: paths) != nil)
        withExtendedLifetime(first) {}
    }

    @Test func providesTerminalAndCleansUp() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("child.pid")
        let process = try ManagedChildProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [
            "-c", "test -t 0 && test -t 1 && test -t 2 && stty -a >/dev/null || exit 9; sleep 60 & echo $! > \"$0.tmp\"; mv \"$0.tmp\" \"$0\"; wait", pidFile.path
        ], terminal: true)
        defer { process.terminateAndReap() }
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: pidFile.path), Date() < deadline { usleep(10_000) }
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(!process.wait(timeout: 0.05))
        process.terminateAndReap()
        #expect(!processIsLive(pid))
    }
}

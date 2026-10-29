// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Testing
@testable import RationbookCore

@Suite struct CLIInstallTests {
    @Test func removesOnlyOwnedFiles() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = RationbookPaths(root: root.appendingPathComponent("support"))
        let localBin = root.appendingPathComponent("local-bin")
        let manager = CLIIntegrationManager(paths: support, localBin: localBin)
        let record = try manager.install(source: URL(fileURLWithPath: "/bin/echo"))
        #expect(FileManager.default.isExecutableFile(atPath: record.executablePath))
        #expect(URL(fileURLWithPath: record.symlinkPath).resolvingSymlinksInPath().path == record.executablePath)
        try manager.uninstall()
        #expect(!FileManager.default.fileExists(atPath: record.executablePath))
        #expect(!FileManager.default.fileExists(atPath: record.symlinkPath))
    }

    @Test func preservesExistingFiles() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let localBin = root.appendingPathComponent("local-bin")
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("foreign".utf8).write(to: localBin.appendingPathComponent("rationbook"))
        let manager = CLIIntegrationManager(paths: RationbookPaths(root: root.appendingPathComponent("support")), localBin: localBin)
        #expect(throws: (any Error).self) {
            _ = try manager.install(source: URL(fileURLWithPath: "/bin/echo"))
        }
        #expect(try String(contentsOf: localBin.appendingPathComponent("rationbook"), encoding: .utf8) == "foreign")
    }

    @Test func confinesInstallPaths() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = RationbookPaths(root: root.appendingPathComponent("support"))
        let localBin = root.appendingPathComponent("local-bin")
        try support.prepare()
        let foreignPayload = support.binDirectory.appendingPathComponent("rationbook")
        try Data("foreign".utf8).write(to: foreignPayload)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: foreignPayload.path)
        let manager = CLIIntegrationManager(paths: support, localBin: localBin)
        #expect(throws: CLIIntegrationError.self) { _ = try manager.install(source: URL(fileURLWithPath: "/bin/echo")) }
        #expect(try String(contentsOf: foreignPayload, encoding: .utf8) == "foreign")

        try FileManager.default.removeItem(at: foreignPayload)
        let record = try manager.install(source: URL(fileURLWithPath: "/bin/echo"))
        let victim = root.appendingPathComponent("victim")
        try Data("keep".utf8).write(to: victim)
        var forged = record
        forged.executablePath = victim.path
        forged.executableSha256 = FileDigest.sha256(Data("keep".utf8))
        try support.atomicWrite(try RationbookJSON.encoder().encode(forged), to: support.cliIntegration)
        #expect(throws: CLIIntegrationError.self) { try manager.uninstall() }
        #expect(try String(contentsOf: victim, encoding: .utf8) == "keep")
    }

    @Test func recoversPartialInstall() throws {
        let boundaries: [CLIInstallBoundary] = [
            .pendingRecordWritten,
            .payloadWritten,
            .symlinkWritten,
            .ownershipRecordWritten,
        ]
        for boundary in boundaries {
            let outer = try hardeningTemporaryRoot("cli-\(boundary)")
            defer { try? FileManager.default.removeItem(at: outer) }
            let paths = RationbookPaths(root: outer.appendingPathComponent("data"))
            let localBin = outer.appendingPathComponent("local-bin")
            var interrupted = CLIIntegrationManager(paths: paths, localBin: localBin)
            interrupted.installFailureInjector = { reached in
                if reached == boundary { throw InjectedInstallFailure.stop }
            }
            #expect(throws: InjectedInstallFailure.stop) {
                _ = try interrupted.install(source: URL(fileURLWithPath: "/bin/echo"))
            }
            #expect(FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("cli-integration.pending.json").path))

            let recovery = CLIIntegrationManager(paths: paths, localBin: localBin)
            if boundary == .pendingRecordWritten || boundary == .payloadWritten {
                #expect(throws: CLIIntegrationError.self) { try recovery.uninstall() }
            } else {
                try recovery.uninstall()
            }
            #expect(!FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("cli-integration.pending.json").path))
            #expect(!FileManager.default.fileExists(atPath: paths.binDirectory.appendingPathComponent("rationbook").path))
            #expect(!FileManager.default.fileExists(atPath: localBin.appendingPathComponent("rationbook").path))
        }
    }

    @Test func findsRealSiblingHelper() throws {
        let outer = try hardeningTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: outer) }
        let link = outer.appendingPathComponent("rationbook")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: hardeningBuiltProduct("rationbook"))
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "exec -a rationbook \"$1\" claude install-feed", "test", link.path]
        process.currentDirectoryURL = outer
        var environment = ProcessInfo.processInfo.environment
        let home = outer.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let paths = RationbookPaths(root: outer.appendingPathComponent("data"))
        environment["CFFIXED_USER_HOME"] = home.path
        environment["RATIONBOOK_DATA_DIR"] = paths.root.path
        let decoy = outer.appendingPathComponent("rationbook-claude-helper")
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: decoy)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: decoy.path)
        environment.removeValue(forKey: "RATIONBOOK_HELPER_PATH")
        process.environment = environment
        process.standardError = output
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(message)")
        let installed = paths.binDirectory.appendingPathComponent("rationbook-claude-helper")
        #expect(try Data(contentsOf: installed) == Data(contentsOf: hardeningBuiltProduct("rationbook-claude-helper")))
    }
}

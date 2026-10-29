// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Testing
@testable import RationbookCore

@Suite struct ExecutableLocatorTests {
    @Test func skipsUnsafePathEntries() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let unsafeDirectory = root.appendingPathComponent("unsafe", isDirectory: true)
        let safeDirectory = root.appendingPathComponent("safe", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafeDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])
        try FileManager.default.createDirectory(at: safeDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let unsafeExecutable = unsafeDirectory.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: unsafeExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: unsafeExecutable.path)
        let safeLink = safeDirectory.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(at: safeLink, withDestinationURL: URL(fileURLWithPath: "/bin/echo"))

        let located = try ExecutableLocator.locate(
            "codex",
            environment: ["PATH": ".::relative:\(unsafeDirectory.path):\(safeDirectory.path)"],
            homeDirectory: root,
            currentDirectory: root.appendingPathComponent("workspace"),
            standardDirectories: []
        )
        #expect(located == safeLink.resolvingSymlinksInPath())
    }

    @Test func rejectsWritableExecutables() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let unsafeDirectory = root.appendingPathComponent("group-writable", isDirectory: true)
        let safeDirectory = root.appendingPathComponent("safe", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafeDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o770])
        try FileManager.default.createDirectory(at: safeDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let unsafeExecutable = unsafeDirectory.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: unsafeExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: unsafeExecutable.path)
        let safeLink = safeDirectory.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(at: safeLink, withDestinationURL: URL(fileURLWithPath: "/bin/echo"))

        let located = try ExecutableLocator.locate(
            "codex",
            environment: ["PATH": "\(unsafeDirectory.path):\(safeDirectory.path)"],
            homeDirectory: root,
            currentDirectory: root.appendingPathComponent("workspace"),
            standardDirectories: []
        )
        #expect(located == safeLink.resolvingSymlinksInPath())

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unsafeDirectory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o770], ofItemAtPath: unsafeExecutable.path)
        let locatedAfterFileCheck = try ExecutableLocator.locate(
            "codex",
            environment: ["PATH": "\(unsafeDirectory.path):\(safeDirectory.path)"],
            homeDirectory: root,
            currentDirectory: root.appendingPathComponent("workspace"),
            standardDirectories: []
        )
        #expect(locatedAfterFileCheck == safeLink.resolvingSymlinksInPath())
    }

    @Test func pinsExecutableInode() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("provider")
        try Data("validated-provider".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)

        let prepared = try ExecutableLocator.privateLaunchAnchor(for: source, executableName: "provider")
        defer { prepared.cleanup() }
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let anchorAttributes = try FileManager.default.attributesOfItem(atPath: prepared.executableURL.path)
        #expect(originalAttributes[.systemFileNumber] as? NSNumber == anchorAttributes[.systemFileNumber] as? NSNumber)

        try Data("replacement".utf8).write(to: source, options: .atomic)
        #expect(try Data(contentsOf: prepared.executableURL) == Data("validated-provider".utf8))
        let replacedAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
        #expect(replacedAttributes[.systemFileNumber] as? NSNumber != anchorAttributes[.systemFileNumber] as? NSNumber)
    }

    @Test func usesProtectedTemporaryDirectory() throws {
        let directory = try ExecutableLocator.trustedUserTemporaryDirectory()
        var status = stat()
        #expect(lstat(directory.path, &status) == 0)
        #expect((status.st_mode & S_IFMT) == S_IFDIR)
        #expect(status.st_uid == getuid())
        #expect((status.st_mode & 0o077) == 0)
    }

    @Test func acceptsLaunchServicesRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RationbookLaunchServices-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = root.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tools,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let executable = tools.appendingPathComponent("provider")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let located = try ExecutableLocator.locate(
            "provider",
            environment: ["PATH": ""],
            homeDirectory: root,
            currentDirectory: URL(fileURLWithPath: "/", isDirectory: true),
            standardDirectories: [tools]
        )

        #expect(located == executable)
    }

    @Test func rejectsUnsignedSibling() throws {
        let root = try providerSecurityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let project = workspace.appendingPathComponent("project", isDirectory: true)
        let tools = workspace.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try makeUnsignedProvider(at: tools.appendingPathComponent("codex"))

        #expect(throws: ProcessRunnerError.self) {
            _ = try ExecutableLocator.locate(
                "codex",
                environment: ["PATH": tools.path],
                homeDirectory: root,
                currentDirectory: project,
                standardDirectories: []
            )
        }
    }

    @Test func rejectsUnsignedAncestor() throws {
        let root = try providerSecurityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let project = workspace.appendingPathComponent("nested/project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try makeUnsignedProvider(at: workspace.appendingPathComponent("codex"))

        #expect(throws: ProcessRunnerError.self) {
            _ = try ExecutableLocator.locate(
                "codex",
                environment: ["PATH": workspace.path],
                homeDirectory: root,
                currentDirectory: project,
                standardDirectories: []
            )
        }
    }

    @Test func checksSymlinkTarget() throws {
        let root = try providerSecurityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let project = workspace.appendingPathComponent("project", isDirectory: true)
        let realTools = workspace.appendingPathComponent("tools", isDirectory: true)
        let pathAlias = root.appendingPathComponent("apparently-external", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try makeUnsignedProvider(at: realTools.appendingPathComponent("codex"))
        try FileManager.default.createSymbolicLink(at: pathAlias, withDestinationURL: realTools)

        #expect(throws: ProcessRunnerError.self) {
            _ = try ExecutableLocator.locate(
                "codex",
                environment: ["PATH": pathAlias.path],
                homeDirectory: root,
                currentDirectory: project,
                standardDirectories: []
            )
        }
    }

    @Test func acceptsUserLocalInstall() throws {
        let root = try providerSecurityRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("workspace/project", isDirectory: true)
        let localBin = root.appendingPathComponent(".local/bin", isDirectory: true)
        let provider = localBin.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try makeUnsignedProvider(at: provider)

        let located = try ExecutableLocator.locate(
            "codex",
            environment: ["PATH": localBin.path],
            homeDirectory: root,
            currentDirectory: project,
            standardDirectories: []
        )
        #expect(located == provider.resolvingSymlinksInPath())
    }
}

// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Testing
@testable import RationbookCore

@Suite struct PathTests {
    @Test func preservesSymlinkTarget() throws {
        let outer = try hardeningTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: outer) }
        let target = outer.appendingPathComponent("target", isDirectory: true)
        let link = outer.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: RationbookPathError.self) { try RationbookPaths(root: link).prepare() }
        let mode = try #require(FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o777 == 0o755)
    }

    @Test func confinesAtomicWrites() throws {
        let outer = try hardeningTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: outer) }
        let paths = RationbookPaths(root: outer.appendingPathComponent("data"))
        try paths.prepare()
        let victim = outer.appendingPathComponent("victim")
        try Data("untouched".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(at: paths.claudeIntegration, withDestinationURL: victim)
        #expect(throws: RationbookPathError.self) { try paths.atomicWrite(Data("changed".utf8), to: paths.claudeIntegration) }
        #expect(throws: RationbookPathError.self) { try paths.atomicWrite(Data("changed".utf8), to: victim) }
        #expect(try String(contentsOf: victim, encoding: .utf8) == "untouched")
    }

    @Test func rejectsSymlinkedLock() throws {
        let outer = try hardeningTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: outer) }
        let paths = RationbookPaths(root: outer.appendingPathComponent("data"))
        try paths.prepare()
        let victim = outer.appendingPathComponent("victim")
        try Data("untouched".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(
            at: paths.locksDirectory.appendingPathComponent("anthropic.lock"),
            withDestinationURL: victim
        )
        #expect(ProviderRefreshLock(provider: "anthropic", paths: paths) == nil)
        #expect(try String(contentsOf: victim, encoding: .utf8) == "untouched")
    }

    @Test(arguments: [true, false])
    func sharesDataAcrossTemporaryAliases(existingRoot: Bool) throws {
        let parent = try temporaryAliasParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let data = parent.appendingPathComponent("data", isDirectory: true)
        if existingRoot {
            // Reopening an already-existing directory is the reported failure.
            try FileManager.default.createDirectory(
                at: data, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
        }
        let first = RationbookPaths(root: data)
        let second = RationbookPaths(root: URL(fileURLWithPath: "/tmp/\(parent.lastPathComponent)/data", isDirectory: true))
        try first.prepare()
        try second.prepare()
        #expect(first.root.resolvingSymlinksInPath() == second.root.resolvingSymlinksInPath())

        let firstFile = first.root.appendingPathComponent("shared.txt")
        let secondFile = second.root.appendingPathComponent("shared.txt")
        try first.atomicWrite(Data("first".utf8), to: firstFile)
        try second.validateFileForRead(secondFile)
        #expect(try Data(contentsOf: secondFile) == Data("first".utf8))
        try second.atomicWrite(Data("second".utf8), to: secondFile)
        try first.validateFileForRead(firstFile)
        #expect(try Data(contentsOf: firstFile) == Data("second".utf8))

        for directory in [first.root, first.binDirectory, first.locksDirectory] {
            let mode = try #require(FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)
            #expect(mode.intValue & 0o777 == 0o700)
        }
        let fileMode = try #require(FileManager.default.attributesOfItem(atPath: firstFile.path)[.posixPermissions] as? NSNumber)
        #expect(fileMode.intValue & 0o777 == 0o600)

        let outside = parent.appendingPathComponent("data-sibling.txt")
        try Data("untouched".utf8).write(to: outside)
        for paths in [first, second] {
            for prefix in ["/private/tmp", "/tmp"] {
                let destination = URL(fileURLWithPath: "\(prefix)/\(parent.lastPathComponent)/data-sibling.txt")
                #expect(throws: RationbookPathError.pathOutsideRoot(destination.standardizedFileURL.path)) {
                    try paths.atomicWrite(Data("changed".utf8), to: destination)
                }
            }
        }
        #expect(try Data(contentsOf: outside) == Data("untouched".utf8))
    }

    @Test(arguments: ["/private/tmp", "/tmp"], [".", ".."])
    func rejectsDotSegments(prefix: String, segment: String) throws {
        let parent = try temporaryAliasParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let data = parent.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(
            at: data, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755]
        )
        let anchor = parent.appendingPathComponent("anchor", isDirectory: true)
        try FileManager.default.createDirectory(
            at: anchor, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        let traversal = segment == ".." ? "anchor/.." : "."
        let requested = URL(fileURLWithPath: "\(prefix)/\(parent.lastPathComponent)/\(traversal)/data", isDirectory: true)
        #expect(requested.path.split(separator: "/").contains(Substring(segment)))
        let paths = RationbookPaths(root: requested)
        #expect(throws: RationbookPathError.unsafeRoot(requested.standardizedFileURL.path)) {
            try paths.prepare()
        }
        let mode = try #require(FileManager.default.attributesOfItem(atPath: data.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o777 == 0o755)
        #expect(try FileManager.default.contentsOfDirectory(atPath: data.path).isEmpty)
    }

    @Test(arguments: ["/private/tmp", "/tmp"])
    func rejectsSymlinkRoots(prefix: String) throws {
        let parent = try temporaryAliasParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(
            at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755]
        )
        let victim = target.appendingPathComponent("victim.txt")
        try Data("untouched".utf8).write(to: victim)
        let link = URL(fileURLWithPath: "\(prefix)/\(parent.lastPathComponent)/data", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let paths = RationbookPaths(root: link)
        #expect(throws: RationbookPathError.unsafeRoot(link.standardizedFileURL.path)) {
            try paths.prepare()
        }
        #expect(throws: RationbookPathError.self) {
            try paths.atomicWrite(Data("changed".utf8), to: paths.root.appendingPathComponent("victim.txt"))
        }
        let mode = try #require(FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o777 == 0o755)
        #expect(try Data(contentsOf: victim) == Data("untouched".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == ["victim.txt"])
    }
}

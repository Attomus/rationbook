// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Testing
@testable import RationbookCore

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// Positive security fixtures must satisfy the production file contract regardless
// of the test worker's umask. Deliberately unsafe modes remain explicit in tests.

extension Data {
    func writePrivateFixture(to url: URL) throws {
        try write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

func temporaryRoot(_ label: String = #function) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RationbookTests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return root
}

/// `kill(pid, 0)` also succeeds for a terminated process that is briefly a
/// zombie while launchd adopts and reaps it. Treat that state as terminated:
/// the descendant cannot execute, retain descriptors, or consume resources.

func processIsLive(_ pid: pid_t) -> Bool {
    guard kill(pid, 0) == 0 || errno == EPERM else { return false }
    var info = proc_bsdinfo()
    let byteCount = proc_pidinfo(
        pid,
        PROC_PIDTBSDINFO,
        0,
        &info,
        Int32(MemoryLayout<proc_bsdinfo>.size)
    )
    guard byteCount == MemoryLayout<proc_bsdinfo>.size else { return false }
    return info.pbi_status != SZOMB
}

func builtProduct(_ name: String) throws -> URL {
    let bundledCandidate = Bundle.module.bundleURL.deletingLastPathComponent().appendingPathComponent(name)
    if FileManager.default.isExecutableFile(atPath: bundledCandidate.path) {
        return bundledCandidate
    }

    var current = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    while current.path != "/" {
        if current.lastPathComponent.lowercased() == "debug" || current.lastPathComponent.lowercased() == "release" {
            let candidate = current.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        current.deleteLastPathComponent()
    }

    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let build = repository.appendingPathComponent(".build", isDirectory: true)
    let enumerator = try #require(FileManager.default.enumerator(at: build, includingPropertiesForKeys: [.isRegularFileKey]))
    var candidates: [URL] = []
    for case let url as URL in enumerator where url.lastPathComponent == name && FileManager.default.isExecutableFile(atPath: url.path) {
        candidates.append(url)
    }
    if let debug = candidates.first(where: { $0.path.lowercased().contains("/debug/") }) { return debug }
    if let candidate = candidates.first { return candidate }
    Issue.record("Could not locate built product \(name)")
    throw CocoaError(.fileNoSuchFile)
}

func runCLI(_ arguments: [String], dataRoot: URL) throws -> (Int32, Data, Data) {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = try builtProduct("rationbook")
    process.arguments = arguments
    process.standardOutput = stdout
    process.standardError = stderr
    var environment = ProcessInfo.processInfo.environment
    environment["RATIONBOOK_DATA_DIR"] = dataRoot.path
    process.environment = environment
    try process.run()
    process.waitUntilExit()
    return (process.terminationStatus, stdout.fileHandleForReading.readDataToEndOfFile(), stderr.fileHandleForReading.readDataToEndOfFile())
}

func provider(observedAt: Date, used: Double, freshness: Freshness = .fresh) -> ProviderStatus {
    ProviderStatus(
        provider: "openai",
        agentLabel: "OpenAI",
        state: .available,
        capabilities: AdapterCapabilities(supportsOnDemandRefresh: true, supportsPushUpdates: true),
        source: SourceMetadata(name: "fixture", documentation: "local_observed", maturity: "test"),
        windows: [QuotaWindow(
            id: "openai:codex:300", displayLabel: "5 hour", durationSeconds: 18_000,
            observedAt: observedAt, freshness: freshness, usedPercent: used,
            expectedResetsAt: Date(timeIntervalSince1970: 20_000), dataQuality: .authoritative
        )]
    )
}

struct TestCapacitySource: CapacitySource {
    let snapshot: CapacitySourceSnapshot
    var sourceID: String { "test_capacity_source" }

    func refresh(now: Date) throws -> CapacitySourceSnapshot {
        snapshot
    }
}

func hardeningTemporaryRoot(_ label: String = #function) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RationbookHardening-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return root
}

func hardeningBuiltProduct(_ name: String) throws -> URL {
    let bundledCandidate = Bundle.module.bundleURL.deletingLastPathComponent().appendingPathComponent(name)
    if FileManager.default.isExecutableFile(atPath: bundledCandidate.path) {
        return bundledCandidate
    }

    var current = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    while current.path != "/" {
        if current.lastPathComponent.lowercased() == "debug" || current.lastPathComponent.lowercased() == "release" {
            let candidate = current.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        current.deleteLastPathComponent()
    }

    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let enumerator = try #require(FileManager.default.enumerator(
        at: repository.appendingPathComponent(".build"),
        includingPropertiesForKeys: [.isRegularFileKey]
    ))
    for case let url as URL in enumerator
    where url.lastPathComponent == name && url.path.lowercased().contains("/debug/") && FileManager.default.isExecutableFile(atPath: url.path) {
        return url
    }
    throw CocoaError(.fileNoSuchFile)
}

func installTestHelper(at paths: RationbookPaths, previousCommand: String = "/bin/cat") throws -> URL {
    try paths.prepare()
    let source = try hardeningBuiltProduct("rationbook-claude-helper")
    let helperData = try Data(contentsOf: source)
    let helper = paths.binDirectory.appendingPathComponent("rationbook-claude-helper")
    try paths.atomicWrite(helperData, to: helper, permissions: 0o700)
    let previous = try JSONSerialization.data(
        withJSONObject: ["type": "command", "command": previousCommand],
        options: [.sortedKeys]
    )
    let installed = try JSONSerialization.data(
        withJSONObject: ["type": "command", "command": "'\(helper.path)' --data-root '\(paths.root.path)'"],
        options: [.sortedKeys]
    )
    let record = ClaudeIntegrationRecord(
        schemaVersion: 3,
        installedAt: Date(),
        helperPath: helper.path,
        settingsPath: "/synthetic/settings.json",
        previousStatusLine: previous,
        installedStatusLine: installed,
        helperSha256: FileDigest.sha256(helperData),
        helperVersion: "test",
        canonicalRootPath: paths.root.path
    )
    try paths.atomicWrite(try RationbookJSON.encoder().encode(record), to: paths.claudeIntegration)
    return helper
}

func runTestHelper(_ helper: URL, root: URL, inheritedRoot: URL? = nil) throws -> (Int32, Data) {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    process.executableURL = helper
    process.arguments = ["--data-root", root.path]
    process.standardInput = input
    process.standardOutput = output
    if let inheritedRoot {
        var environment = ProcessInfo.processInfo.environment
        environment["RATIONBOOK_DATA_DIR"] = inheritedRoot.path
        process.environment = environment
    }
    let payload = Data(#"{"version":"test","rate_limits":{"five_hour":{"used_percentage":5}}}"#.utf8)
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: payload)
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    return (process.terminationStatus, output.fileHandleForReading.readDataToEndOfFile())
}

final class InstallResults: @unchecked Sendable {
    let lock = NSLock()
    var successes = 0
    var failures: [Error] = []
}

enum InjectedInstallFailure: Error {
    case stop
}

func providerSecurityRoot(_ label: String = #function) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "RationbookProviderSecurityTests-\(label)-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return root
}

func makeUnsignedProvider(at url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755]
    )
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

func temporaryAliasParent() throws -> URL {
    let parent = URL(fileURLWithPath: "/private/tmp/rationbook-alias-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
    )
    return parent
}

// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Security

private final class BoundedProcessCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private(set) var overflowed = false

    init(limit: Int) { self.limit = limit }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        let available = max(0, limit - storage.count)
        storage.append(data.prefix(available))
        if data.count > available { overflowed = true }
    }

    func result() -> (Data, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (storage, overflowed)
    }
}

public enum ProcessRunnerError: Error, LocalizedError, Sendable {
    case executableNotFound(String)
    case unsafeExecutable(String)
    case timedOut(String)
    case failed(String, Int32, String)
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let name): return "\(name) executable was not found."
        case .unsafeExecutable(let path): return "Refusing unsafe executable at \(path)."
        case .timedOut(let name): return "\(name) timed out."
        case .failed(let name, let status, let detail): return "\(name) failed with status \(status): \(detail)"
        case .invalidOutput(let detail): return "Provider returned invalid output: \(detail)"
        }
    }
}

public struct ProcessOutput: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32
}

public enum ExecutableLocator {
    public static func locate(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        standardDirectories: [URL]? = nil
    ) throws -> URL {
        let supportedDirectories = supportedInstallationDirectories(homeDirectory: homeDirectory)
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty && $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let trustedFallbacks = standardDirectories ?? supportedDirectories
        let candidates = pathDirectories.map { ($0, false) } + trustedFallbacks.map { ($0, true) }
        let canonicalCurrentDirectory = currentDirectory.resolvingSymlinksInPath()
        // LaunchServices starts GUI applications with `/` as their working
        // directory. Treating the filesystem root as a caller workspace would
        // classify every absolute executable path as repository-local.
        let hasScopedCurrentDirectory = canonicalCurrentDirectory.path != "/"
        var seen = Set<String>()
        var firstUnsafe: ProcessRunnerError?
        for (directory, explicitlyTrustedDirectory) in candidates {
            let candidate = directory.appendingPathComponent(name).standardizedFileURL
            let candidateKey = "\(explicitlyTrustedDirectory):\(candidate.path)"
            guard seen.insert(candidateKey).inserted else { continue }
            let url = candidate.resolvingSymlinksInPath()
            guard FileManager.default.isExecutableFile(atPath: url.path) else { continue }
            let unsafe: Bool
            if hasScopedCurrentDirectory, isWithin(url, directory: canonicalCurrentDirectory) {
                unsafe = true
            } else if !isTrustedInstallation(
                candidate: candidate,
                resolved: url,
                explicitlyTrustedDirectory: explicitlyTrustedDirectory,
                supportedDirectories: supportedDirectories,
                customTrustedDirectories: trustedFallbacks
            ), !hasExpectedVendorSignature(url, executableName: name) {
                // PATH is inherited by every caller, including callers launched from
                // a repository. Ownership and mode checks alone cannot distinguish a
                // deliberately executable repository file from an installed tool.
                unsafe = true
            } else {
                unsafe = try isUnsafe(url, executableName: name)
            }
            if unsafe {
                firstUnsafe = firstUnsafe ?? .unsafeExecutable(url.path)
                continue
            }
            return url
        }
        if let firstUnsafe { throw firstUnsafe }
        throw ProcessRunnerError.executableNotFound(name)
    }

    private static func supportedInstallationDirectories(homeDirectory: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            homeDirectory.appendingPathComponent(".local/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/bin", isDirectory: true),
        ]
    }

    private static func isTrustedInstallation(
        candidate: URL,
        resolved: URL,
        explicitlyTrustedDirectory: Bool,
        supportedDirectories: [URL],
        customTrustedDirectories: [URL]
    ) -> Bool {
        // A canonical system binary is safe even when reached through a PATH
        // symlink. This also avoids treating /bin -> /usr/bin as untrusted.
        let systemDirectories = ["/usr/bin", "/bin"].map {
            URL(fileURLWithPath: $0, isDirectory: true).resolvingSymlinksInPath()
        }
        if systemDirectories.contains(resolved.deletingLastPathComponent()) { return true }

        let candidateDirectory = candidate.deletingLastPathComponent().standardizedFileURL
        let supportedDirectory = supportedDirectories.first {
            candidateDirectory == $0.standardizedFileURL
        }
        if let supportedDirectory {
            let installRoot = supportedDirectory.deletingLastPathComponent().resolvingSymlinksInPath()
            // Regular files in a supported bin directory and normal package-manager
            // links that remain under the same installation root are allowed. A bin
            // link back into a repository is not.
            if resolved == candidate.resolvingSymlinksInPath(),
               resolved.deletingLastPathComponent() == supportedDirectory.resolvingSymlinksInPath() {
                return true
            }
            return isWithin(resolved, directory: installRoot)
        }

        // Non-production callers may inject an explicit trusted directory. Preserve
        // that API contract without allowing inherited PATH entries to self-declare
        // trust merely by using an absolute path.
        return explicitlyTrustedDirectory && customTrustedDirectories.contains {
            candidateDirectory == $0.standardizedFileURL
        }
    }

    static func prepareForLaunch(_ url: URL) throws -> PreparedExecutableLaunch {
        let resolved = url.resolvingSymlinksInPath()
        guard let needsBoundLaunch = try safetyResult(resolved, executableName: url.lastPathComponent) else {
            throw ProcessRunnerError.unsafeExecutable(url.path)
        }
        guard needsBoundLaunch else {
            return PreparedExecutableLaunch(executableURL: resolved, cleanupDirectory: nil)
        }

        let prepared = try privateLaunchAnchor(for: resolved, executableName: url.lastPathComponent)
        do {
            guard hasExpectedVendorSignature(prepared.executableURL, executableName: url.lastPathComponent),
                  try safetyResult(prepared.executableURL, executableName: url.lastPathComponent) != nil else {
                throw ProcessRunnerError.unsafeExecutable(url.path)
            }
            return prepared
        } catch {
            prepared.cleanup()
            throw error
        }
    }

    static func privateLaunchAnchor(for source: URL, executableName: String) throws -> PreparedExecutableLaunch {
        let directory = try trustedUserTemporaryDirectory().appendingPathComponent(
            "Rationbook-Launch-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let anchor = directory.appendingPathComponent(executableName)
            guard link(source.path, anchor.path) == 0 else {
                throw ProcessRunnerError.unsafeExecutable(source.path)
            }
            return PreparedExecutableLaunch(executableURL: anchor, cleanupDirectory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Returns macOS's per-user temporary directory without consulting `TMPDIR`.
    /// The directory is suitable for a launch anchor only while it remains owned
    /// by this user and inaccessible to group and other users.
    static func trustedUserTemporaryDirectory() throws -> URL {
        let requiredLength = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard requiredLength > 1 else {
            throw ProcessRunnerError.unsafeExecutable("system temporary directory")
        }
        var buffer = [CChar](repeating: 0, count: requiredLength)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, requiredLength) > 0 else {
            throw ProcessRunnerError.unsafeExecutable("system temporary directory")
        }

        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var status = stat()
        guard lstat(directory.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == getuid(),
              (status.st_mode & 0o077) == 0 else {
            throw ProcessRunnerError.unsafeExecutable(directory.path)
        }
        try FileTrust.validateDirectoryChain(directory)
        return directory
    }

    private static func isUnsafe(_ url: URL, executableName: String) throws -> Bool {
        try safetyResult(url, executableName: executableName) == nil
    }

    /// Returns whether launch must be bound to a private hard link. `nil` means unsafe.
    private static func safetyResult(_ url: URL, executableName: String) throws -> Bool? {
        do { try FileTrust.rejectMutationACL(url) } catch { return nil }
        let executableAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard executableAttributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        if let owner = executableAttributes[.ownerAccountID] as? NSNumber,
           owner.uint32Value != 0, owner.uint32Value != getuid() {
            return nil
        }
        if let permissions = executableAttributes[.posixPermissions] as? NSNumber {
            if permissions.intValue & 0o002 != 0 { return nil }
            if permissions.intValue & 0o020 != 0 { return nil }
        }
        var groupWritableAncestor = false
        var current = url.deletingLastPathComponent()
        while current.path != "/" {
            do { try FileTrust.rejectMutationACL(current) } catch { return nil }
            let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
            if let owner = attributes[.ownerAccountID] as? NSNumber,
               owner.uint32Value != 0, owner.uint32Value != getuid() {
                return nil
            }
            if let permissions = attributes[.posixPermissions] as? NSNumber {
                if permissions.intValue & 0o002 != 0 { return nil }
                if permissions.intValue & 0o020 != 0 { groupWritableAncestor = true }
            }
            current.deleteLastPathComponent()
        }
        if groupWritableAncestor,
           !hasExpectedVendorSignature(url, executableName: executableName) {
            return nil
        }
        return groupWritableAncestor
    }

    private static func hasExpectedVendorSignature(_ url: URL, executableName: String) -> Bool {
        let requirementText: String?
        switch executableName {
        case "codex":
            requirementText = "anchor apple generic and identifier \"codex\" and certificate leaf[subject.OU] = \"2DC432GLL2\""
        case "claude":
            requirementText = "anchor apple generic and identifier \"com.anthropic.claude-code\" and certificate leaf[subject.OU] = \"Q6L2SF6YDW\""
        default:
            requirementText = nil
        }
        guard let requirementText else { return false }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(
                code,
                SecCSFlags(rawValue: kSecCSStrictValidate),
                requirement
              ) == errSecSuccess else {
            return false
        }
        return true
    }

    private static func isWithin(_ url: URL, directory: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let root = directory.standardizedFileURL.path
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

struct PreparedExecutableLaunch {
    let executableURL: URL
    let cleanupDirectory: URL?

    init(executableURL: URL, cleanupDirectory: URL?) {
        self.executableURL = executableURL
        self.cleanupDirectory = cleanupDirectory
    }

    func cleanup() {
        guard let cleanupDirectory else { return }
        try? FileManager.default.removeItem(at: cleanupDirectory)
    }
}

public enum ProcessRunner {
    public static func run(
        executable: URL,
        arguments: [String],
        stdin: Data? = nil,
        timeout: TimeInterval = 5,
        maxOutputBytes: Int = 1_048_576,
        acceptedExitCodes: Set<Int32> = [0]
    ) throws -> ProcessOutput {
        let process = try ManagedChildProcess(executable: executable, arguments: arguments)
        defer { process.terminateAndReap() }

        let stdoutCapture = BoundedProcessCapture(limit: maxOutputBytes)
        let stderrCapture = BoundedProcessCapture(limit: maxOutputBytes)
        process.standardOutput.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stdoutCapture.append(data) }
        }
        process.standardError.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stderrCapture.append(data) }
        }

        if let stdin {
            try process.standardInput.write(contentsOf: stdin)
        }
        try? process.standardInput.close()

        if !process.wait(timeout: timeout) {
            process.terminateAndReap()
            process.standardOutput.readabilityHandler = nil
            process.standardError.readabilityHandler = nil
            throw ProcessRunnerError.timedOut(executable.lastPathComponent)
        }

        process.standardOutput.readabilityHandler = nil
        process.standardError.readabilityHandler = nil
        stdoutCapture.append(process.standardOutput.readDataToEndOfFile())
        stderrCapture.append(process.standardError.readDataToEndOfFile())
        let (stdout, stdoutOverflow) = stdoutCapture.result()
        let (stderr, stderrOverflow) = stderrCapture.result()
        guard !stdoutOverflow, !stderrOverflow else {
            throw ProcessRunnerError.invalidOutput("\(executable.lastPathComponent) output exceeded \(maxOutputBytes) bytes.")
        }
        let output = ProcessOutput(stdout: stdout, stderr: stderr, exitCode: process.exitCode)
        guard acceptedExitCodes.contains(output.exitCode) else {
            let detail = String(data: stderr.prefix(4_096), encoding: .utf8) ?? ""
            throw ProcessRunnerError.failed(executable.lastPathComponent, output.exitCode, detail)
        }
        return output
    }

    public static func version(executable: URL, timeout: TimeInterval = 2) -> String? {
        guard let output = try? run(executable: executable, arguments: ["--version"], timeout: timeout) else { return nil }
        return String(data: output.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

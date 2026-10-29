// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

public enum RationbookPathError: Error, LocalizedError, Equatable {
    case rootMustBeAbsolute
    case unsafeRoot(String)
    case unsafePath(String)
    case pathOutsideRoot(String)

    public var errorDescription: String? {
        switch self {
        case .rootMustBeAbsolute:
            return "RATIONBOOK_DATA_DIR must be an absolute path."
        case .unsafeRoot(let path):
            return "Rationbook data directory is not a private, current-user-owned directory: \(path)"
        case .unsafePath(let path):
            return "Rationbook refused an unsafe file or directory: \(path)"
        case .pathOutsideRoot(let path):
            return "Rationbook refused a path outside its data directory: \(path)"
        }
    }
}

public struct RationbookPaths: Sendable {
    public let root: URL
    private let requestedRoot: URL
    private let rootWasAbsolute: Bool
    private let rootWasLexicallyCanonical: Bool

    public init(root: URL? = nil) {
        let requested: URL
        let wasAbsolute: Bool
        if let root {
            requested = root
            wasAbsolute = root.path.hasPrefix("/")
        } else if let override = ProcessInfo.processInfo.environment["RATIONBOOK_DATA_DIR"], !override.isEmpty {
            requested = URL(fileURLWithPath: override, isDirectory: true)
            wasAbsolute = override.hasPrefix("/")
        } else {
            requested = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Rationbook", isDirectory: true)
            wasAbsolute = true
        }
        self.requestedRoot = requested.standardizedFileURL
        self.rootWasAbsolute = wasAbsolute
        // Check lexical traversal separately from Foundation's OS alias
        // normalization, which can rewrite an existing /private/tmp root to /tmp.
        self.rootWasLexicallyCanonical = !requested.path.split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst().contains { $0.isEmpty || $0 == "." || $0 == ".." }
        // Bind all children to one stable root spelling. Existing system aliases
        // such as /var -> /private/var are resolved here; prepare() separately
        // rejects a data root that is itself a symbolic link.
        self.root = requested.standardizedFileURL.resolvingSymlinksInPath()
    }

    public var database: URL { root.appendingPathComponent("rationbook.sqlite3") }
    public var claudeObservation: URL { root.appendingPathComponent("claude-observation.json") }
    public var modelCapacitySupplement: URL { root.appendingPathComponent("model-capacity-supplement.json") }
    public var claudeIntegration: URL { root.appendingPathComponent("claude-integration.json") }
    public var cliIntegration: URL { root.appendingPathComponent("cli-integration.json") }
    public var binDirectory: URL { root.appendingPathComponent("bin", isDirectory: true) }
    public var locksDirectory: URL { root.appendingPathComponent("locks", isDirectory: true) }

    public func prepare() throws {
        guard rootWasAbsolute else { throw RationbookPathError.rootMustBeAbsolute }
        guard rootWasLexicallyCanonical else { throw RationbookPathError.unsafeRoot(requestedRoot.path) }
        if itemExists(requestedRoot) {
            var requestedStatus = stat()
            guard lstat(requestedRoot.path, &requestedStatus) == 0,
                  requestedStatus.st_mode & S_IFMT != S_IFLNK else {
                throw RationbookPathError.unsafeRoot(requestedRoot.path)
            }
        }

        try FileTrust.validateDirectoryChain(root)
        try ensurePrivateDirectory(root)
        try ensurePrivateDirectory(binDirectory)
        try ensurePrivateDirectory(locksDirectory)
        for file in criticalFiles where itemExists(file) {
            try validateOwnedRegularFile(file)
        }
    }

    /// Validates a Rationbook-owned file immediately before a read. Missing files
    /// remain the caller's concern.
    public func validateFileForRead(_ url: URL) throws {
        try prepare()
        _ = try confinedURL(url)
        try validateOwnedRegularFile(url)
    }

    public func atomicWrite(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
        try prepare()
        let destination = try confinedURL(url)
        let parent = destination.deletingLastPathComponent()
        try validateOwnedDirectory(parent)
        if itemExists(destination) { try validateOwnedRegularFile(destination) }

        let temporary = parent.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(permissions))
        guard descriptor >= 0 else { throw RationbookPathError.unsafePath(temporary.path) }
        var shouldRemove = true
        defer {
            close(descriptor)
            if shouldRemove { try? FileManager.default.removeItem(at: temporary) }
        }
        try data.withUnsafeBytes { rawBuffer in
            var remaining = rawBuffer.count
            var cursor = rawBuffer.baseAddress
            while remaining > 0 {
                let count = write(descriptor, cursor, remaining)
                guard count > 0 else { throw RationbookPathError.unsafePath(temporary.path) }
                remaining -= count
                cursor = cursor?.advanced(by: count)
            }
        }
        guard fchmod(descriptor, mode_t(permissions)) == 0, fsync(descriptor) == 0 else {
            throw RationbookPathError.unsafePath(temporary.path)
        }
        try validateOwnedDirectory(parent)
        if itemExists(destination) { try validateOwnedRegularFile(destination) }
        guard rename(temporary.path, destination.path) == 0 else {
            throw RationbookPathError.unsafePath(destination.path)
        }
        shouldRemove = false
        try validateOwnedRegularFile(destination)
    }

    /// Removes only a regular, current-user-owned file confined to this root.
    public func removeOwnedFile(_ url: URL) throws {
        try prepare()
        let confined = try confinedURL(url)
        try validateOwnedRegularFile(confined)
        guard unlink(confined.path) == 0 else { throw RationbookPathError.unsafePath(confined.path) }
    }

    public func confinedURL(_ url: URL) throws -> URL {
        let candidate = url.standardizedFileURL
        // Foundation may normalize existing children differently from new ones
        // when a /private/tmp root was created after init. Confine both spellings.
        let isConfined = [root.path, root.standardizedFileURL.path].contains { spelling in
            let rootPath = spelling.hasSuffix("/") ? spelling : spelling + "/"
            return candidate.path.hasPrefix(rootPath) && candidate.path != spelling
        }
        guard isConfined else {
            throw RationbookPathError.pathOutsideRoot(candidate.path)
        }
        return candidate
    }

    private var criticalFiles: [URL] {
        [
            database,
            URL(fileURLWithPath: database.path + "-wal"),
            URL(fileURLWithPath: database.path + "-shm"),
            claudeObservation,
            modelCapacitySupplement,
            claudeIntegration,
            cliIntegration,
        ]
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        try FileTrust.createDirectory(url)
        try FileTrust.rejectMutationACL(url)
        try validateOwnedDirectory(url, requirePrivate: false)
        // chmod only after lstat established this is our real directory.
        guard chmod(url.path, 0o700) == 0 else { throw RationbookPathError.unsafeRoot(url.path) }
        try validateOwnedDirectory(url)
    }

    private func validateOwnedDirectory(_ url: URL, requirePrivate: Bool = true) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              !requirePrivate || status.st_mode & 0o077 == 0 else {
            throw RationbookPathError.unsafeRoot(url.path)
        }
    }

    private func validateOwnedRegularFile(_ url: URL) throws {
        try FileTrust.rejectMutationACL(url)
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o022 == 0 else {
            throw RationbookPathError.unsafePath(url.path)
        }
    }

    private func itemExists(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
    }
}

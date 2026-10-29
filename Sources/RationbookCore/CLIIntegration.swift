// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Darwin
import Foundation

public struct CLIIntegrationRecord: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var installedAt: Date
    public var executablePath: String
    public var executableSha256: String
    public var symlinkPath: String
}

public enum FileDigest {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum CLIIntegrationError: Error, LocalizedError {
    case sourceMissing
    case destinationOwnedByAnotherFile(String)
    case installedPayloadChanged
    case notInstalled
    case integrationBusy

    public var errorDescription: String? {
        switch self {
        case .sourceMissing: return "The bundled Rationbook CLI was not found."
        case .destinationOwnedByAnotherFile(let path): return "Refusing to replace an existing non-Rationbook file at \(path)."
        case .installedPayloadChanged: return "The installed Rationbook CLI changed; refusing to remove it."
        case .notInstalled: return "The Rationbook CLI is not installed."
        case .integrationBusy: return "Another Rationbook process is changing the CLI integration."
        }
    }
}

enum CLIInstallBoundary: Equatable, Sendable {
    case pendingRecordWritten
    case payloadWritten
    case symlinkWritten
    case ownershipRecordWritten
}

private struct PendingCLIIntegration: Codable {
    var schemaVersion: Int
    var intendedRecord: CLIIntegrationRecord
}

public struct CLIIntegrationManager: Sendable {
    public var paths: RationbookPaths
    public var localBin: URL
    var installFailureInjector: (@Sendable (CLIInstallBoundary) throws -> Void)?

    public init(paths: RationbookPaths = RationbookPaths(), localBin: URL? = nil) {
        self.paths = paths
        self.localBin = localBin ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
        self.installFailureInjector = nil
    }

    public func install(source: URL) throws -> CLIIntegrationRecord {
        guard FileManager.default.isExecutableFile(atPath: source.path) else { throw CLIIntegrationError.sourceMissing }
        try paths.prepare()
        guard let integrationLock = ProviderRefreshLock(provider: "cli-integration", paths: paths, wait: true) else {
            throw CLIIntegrationError.integrationBusy
        }
        return try withExtendedLifetime(integrationLock) {
            try installLocked(source: source)
        }
    }

    private func installLocked(source: URL) throws -> CLIIntegrationRecord {
        try prepareLocalBin()

        let destination = paths.binDirectory.appendingPathComponent("rationbook")
        let link = localBin.appendingPathComponent("rationbook")
        try recoverPendingInstall(destination: destination, link: link)
        let existingRecord = try readRecordIfPresent()
        if FileManager.default.fileExists(atPath: destination.path) {
            guard let existingRecord,
                  URL(fileURLWithPath: existingRecord.executablePath).standardizedFileURL == destination.standardizedFileURL,
                  URL(fileURLWithPath: existingRecord.symlinkPath).standardizedFileURL == link.standardizedFileURL,
                  FileDigest.sha256(try Data(contentsOf: destination, options: [.mappedIfSafe])) == existingRecord.executableSha256 else {
                throw CLIIntegrationError.destinationOwnedByAnotherFile(destination.path)
            }
        }
        let linkAlreadyInstalled: Bool
        if FileManager.default.fileExists(atPath: link.path) || isSymbolicLink(link) {
            guard isSymbolicLink(link), resolvedLink(link) == destination.standardizedFileURL else {
                throw CLIIntegrationError.destinationOwnedByAnotherFile(link.path)
            }
            linkAlreadyInstalled = true
        } else {
            linkAlreadyInstalled = false
        }

        let data = try Data(contentsOf: source, options: [.mappedIfSafe])
        let record = CLIIntegrationRecord(
            schemaVersion: 1,
            installedAt: existingRecord?.installedAt ?? Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)),
            executablePath: destination.path,
            executableSha256: FileDigest.sha256(data),
            symlinkPath: link.path
        )
        let pending = PendingCLIIntegration(schemaVersion: 1, intendedRecord: record)
        try paths.atomicWrite(try RationbookJSON.encoder(pretty: true).encode(pending), to: pendingRecordURL)
        try installFailureInjector?(.pendingRecordWritten)
        try paths.atomicWrite(data, to: destination, permissions: 0o700)
        try installFailureInjector?(.payloadWritten)
        if !linkAlreadyInstalled {
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        }
        try installFailureInjector?(.symlinkWritten)
        try paths.atomicWrite(try RationbookJSON.encoder(pretty: true).encode(record), to: paths.cliIntegration)
        try installFailureInjector?(.ownershipRecordWritten)
        try paths.removeOwnedFile(pendingRecordURL)
        return record
    }

    public func uninstall() throws {
        try paths.prepare()
        guard let integrationLock = ProviderRefreshLock(provider: "cli-integration", paths: paths, wait: true) else {
            throw CLIIntegrationError.integrationBusy
        }
        try withExtendedLifetime(integrationLock) { try uninstallLocked() }
    }

    private func uninstallLocked() throws {
        try prepareLocalBin()
        let executable = paths.binDirectory.appendingPathComponent("rationbook")
        let link = localBin.appendingPathComponent("rationbook")
        try recoverPendingInstall(destination: executable, link: link)
        guard FileManager.default.fileExists(atPath: paths.cliIntegration.path) else { throw CLIIntegrationError.notInstalled }
        let record = try RationbookJSON.decoder().decode(CLIIntegrationRecord.self, from: Data(contentsOf: paths.cliIntegration))
        guard URL(fileURLWithPath: record.executablePath).standardizedFileURL == executable.standardizedFileURL,
              URL(fileURLWithPath: record.symlinkPath).standardizedFileURL == link.standardizedFileURL else {
            throw CLIIntegrationError.destinationOwnedByAnotherFile(record.executablePath)
        }
        if FileManager.default.fileExists(atPath: executable.path) {
            let currentHash = FileDigest.sha256(try Data(contentsOf: executable, options: [.mappedIfSafe]))
            guard currentHash == record.executableSha256 else { throw CLIIntegrationError.installedPayloadChanged }
        }
        if isSymbolicLink(link) {
            guard resolvedLink(link) == executable.standardizedFileURL else {
                throw CLIIntegrationError.destinationOwnedByAnotherFile(link.path)
            }
            try FileManager.default.removeItem(at: link)
        } else if FileManager.default.fileExists(atPath: link.path) {
            throw CLIIntegrationError.destinationOwnedByAnotherFile(link.path)
        }
        if FileManager.default.fileExists(atPath: executable.path) { try FileManager.default.removeItem(at: executable) }
        try FileManager.default.removeItem(at: paths.cliIntegration)
    }

    private func prepareLocalBin() throws {
        try FileTrust.createDirectory(localBin)
        var status = stat()
        guard lstat(localBin.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(), status.st_mode & 0o022 == 0 else {
            throw RationbookPathError.unsafePath(localBin.path)
        }
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func resolvedLink(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private var pendingRecordURL: URL {
        paths.root.appendingPathComponent("cli-integration.pending.json")
    }

    private func readRecordIfPresent() throws -> CLIIntegrationRecord? {
        guard FileManager.default.fileExists(atPath: paths.cliIntegration.path) else { return nil }
        try paths.validateFileForRead(paths.cliIntegration)
        return try RationbookJSON.decoder().decode(
            CLIIntegrationRecord.self,
            from: Data(contentsOf: paths.cliIntegration, options: [.mappedIfSafe])
        )
    }

    /// Resolves an interrupted install before any new mutation. A fully written
    /// payload and link are committed; a partial fresh install is removed; and
    /// a prior authenticated installation is restored. Foreign files are never
    /// adopted or deleted.
    private func recoverPendingInstall(destination: URL, link: URL) throws {
        guard FileManager.default.fileExists(atPath: pendingRecordURL.path) else { return }
        try paths.validateFileForRead(pendingRecordURL)
        let pending = try RationbookJSON.decoder().decode(
            PendingCLIIntegration.self,
            from: Data(contentsOf: pendingRecordURL, options: [.mappedIfSafe])
        )
        let intended = pending.intendedRecord
        guard pending.schemaVersion == 1,
              URL(fileURLWithPath: intended.executablePath).standardizedFileURL == destination.standardizedFileURL,
              URL(fileURLWithPath: intended.symlinkPath).standardizedFileURL == link.standardizedFileURL else {
            throw CLIIntegrationError.destinationOwnedByAnotherFile(intended.executablePath)
        }

        let currentRecord = try readRecordIfPresent()
        let payloadHash: String?
        if FileManager.default.fileExists(atPath: destination.path) {
            try paths.validateFileForRead(destination)
            payloadHash = FileDigest.sha256(try Data(contentsOf: destination, options: [.mappedIfSafe]))
        } else {
            payloadHash = nil
        }
        let linkExists = FileManager.default.fileExists(atPath: link.path) || isSymbolicLink(link)
        let linkIsOurs = linkExists && isSymbolicLink(link) && resolvedLink(link) == destination.standardizedFileURL
        if linkExists && !linkIsOurs {
            throw CLIIntegrationError.destinationOwnedByAnotherFile(link.path)
        }

        if payloadHash == intended.executableSha256, linkIsOurs {
            try paths.atomicWrite(try RationbookJSON.encoder(pretty: true).encode(intended), to: paths.cliIntegration)
            try paths.removeOwnedFile(pendingRecordURL)
            return
        }

        if let currentRecord,
           URL(fileURLWithPath: currentRecord.executablePath).standardizedFileURL == destination.standardizedFileURL,
           URL(fileURLWithPath: currentRecord.symlinkPath).standardizedFileURL == link.standardizedFileURL,
           payloadHash == currentRecord.executableSha256 {
            if !linkExists {
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
            }
            try paths.removeOwnedFile(pendingRecordURL)
            return
        }

        guard currentRecord == nil else { throw CLIIntegrationError.installedPayloadChanged }
        if let payloadHash {
            guard payloadHash == intended.executableSha256 else {
                throw CLIIntegrationError.destinationOwnedByAnotherFile(destination.path)
            }
        }
        if linkIsOurs { try FileManager.default.removeItem(at: link) }
        if payloadHash != nil { try paths.removeOwnedFile(destination) }
        try paths.removeOwnedFile(pendingRecordURL)
    }

}

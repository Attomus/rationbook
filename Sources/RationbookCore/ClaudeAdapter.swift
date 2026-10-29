// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

public struct ClaudeObservation: Codable, Equatable, Sendable {
    public struct RateLimit: Codable, Equatable, Sendable {
        public var usedPercentage: Double
        public var resetsAt: Double?
    }

    public struct RateLimits: Codable, Equatable, Sendable {
        public var fiveHour: RateLimit?
        public var sevenDay: RateLimit?
        public var spendLimit: RateLimit?

        public init(fiveHour: RateLimit? = nil, sevenDay: RateLimit? = nil, spendLimit: RateLimit? = nil) {
            self.fiveHour = fiveHour
            self.sevenDay = sevenDay
            self.spendLimit = spendLimit
        }
    }

    public var sourceKey: String?
    public var sourceRevision: String?
    public var schemaVersion: Int
    public var observedAt: Date
    public var claudeVersion: String?
    public var rateLimits: RateLimits

    public init(schemaVersion: Int = 1, observedAt: Date, claudeVersion: String?, rateLimits: RateLimits, sourceRevision: String? = nil, sourceKey: String? = nil) {
        self.sourceKey = sourceKey
        self.sourceRevision = sourceRevision
        self.schemaVersion = schemaVersion
        self.observedAt = observedAt
        self.claudeVersion = claudeVersion
        self.rateLimits = rateLimits
    }
    public func shouldReplace(_ previous: ClaudeObservation?) -> Bool {
        guard rateLimits.fiveHour != nil || rateLimits.sevenDay != nil || rateLimits.spendLimit != nil else { return false }
        // A status-line timer can replay cached quota. Only a changed reading,
        // session or API-duration counter establishes another local observation.
        return previous == nil || rateLimits != previous?.rateLimits || sourceRevision != previous?.sourceRevision
    }

}

public struct ClaudeAdapter: ProviderAdapter {
    public let providerID = "anthropic"
    private static let observerCapabilities = AdapterCapabilities(
        supportsOnDemandRefresh: false,
        supportsPushUpdates: false,
        supportsAccountScope: true,
        supportsModelScope: false
    )
    public var capabilities: AdapterCapabilities { Self.observerCapabilities }
    public var agentLabel: String
    public var paths: RationbookPaths

    public init(
        agentLabel: String = "Anthropic",
        paths: RationbookPaths = RationbookPaths()
    ) {
        self.agentLabel = agentLabel
        self.paths = paths
    }

    public func detect() -> ProviderStatus {
        do {
            let executable = try ExecutableLocator.locate("claude")
            let version = ProcessRunner.version(executable: executable)
            return ProviderStatus(
                provider: providerID,
                agentLabel: agentLabel,
                state: .waitingForObservation,
                capabilities: capabilities,
                source: source(version: version),
                errors: [StructuredError(code: "waiting_for_observation", message: "Claude Code is installed but has not emitted a quota observation.")]
            )
        } catch {
            return ProviderErrorMapper.status(provider: providerID, agentLabel: agentLabel, capabilities: capabilities, source: source(version: nil), error: error)
        }
    }

    public func fetch(now: Date = Date()) throws -> ProviderStatus {
        return try fetchObservation(now: now)
    }

    private func fetchObservation(now: Date) throws -> ProviderStatus {
        _ = try ExecutableLocator.locate("claude")
        guard FileManager.default.fileExists(atPath: paths.claudeObservation.path) else {
            return detect()
        }
        let data = try Data(contentsOf: paths.claudeObservation, options: [.mappedIfSafe])
        guard data.count <= 64 * 1_024 else { throw ProcessRunnerError.invalidOutput("Claude observation exceeds 64 KiB.") }
        let observation = try RationbookJSON.decoder().decode(ClaudeObservation.self, from: data)
        try QuotaValidation.observation(observation)
        var status = Self.normalize(observation, now: now, agentLabel: agentLabel)
        do {
            if let supplement = try ModelCapacitySupplementManager(paths: paths).load(now: now) {
                let modelWindows = ModelCapacitySupplementManager.quotaWindows(from: supplement, now: now)
                status.windows += modelWindows
                status.capabilities.supportsModelScope = true
                status.modelSpecificCapacity = modelWindows.contains { [.fresh, .aging].contains($0.freshness) }
                    ? "observed"
                    : "stale"
            } else {
                status.modelSpecificCapacity = "unknown"
            }
        } catch {
            status.state = .partial
            status.modelSpecificCapacity = "invalid"
            status.errors.append(StructuredError(
                code: "model_capacity_supplement_invalid",
                message: "The local model-capacity supplement was rejected."
            ))
        }
        return status
    }

    public static func normalize(_ observation: ClaudeObservation, now: Date = Date(), agentLabel: String = "Anthropic") -> ProviderStatus {
        var windows: [QuotaWindow] = []
        if let value = observation.rateLimits.fiveHour {
            windows.append(window(id: "anthropic:account:five_hour", label: "5 hour", seconds: 18_000, value: value, observedAt: observation.observedAt, now: now))
        }
        if let value = observation.rateLimits.sevenDay {
            windows.append(window(id: "anthropic:account:seven_day", label: "7 day", seconds: 604_800, value: value, observedAt: observation.observedAt, now: now))
        }
        if let value = observation.rateLimits.spendLimit {
            windows.append(window(id: "anthropic:spend:spend_limit", label: "Spend limit", scope: "spend", seconds: nil, value: value, observedAt: observation.observedAt, now: now))
        }
        let state: ProviderState
        var errors: [StructuredError] = []
        if windows.isEmpty {
            state = .waitingForObservation
            errors = [StructuredError(code: "quota_fields_absent", message: "Claude Code has not supplied aggregate quota fields.")]
        } else if windows.allSatisfy({ $0.freshness == .stale }) {
            state = .stale
            errors = [StructuredError(code: "stale_observation", message: "Claude Code has not emitted a recent quota observation.")]
        } else {
            state = .available
        }
        return ProviderStatus(
            provider: "anthropic",
            agentLabel: agentLabel,
            state: state,
            capabilities: Self.observerCapabilities,
            source: SourceMetadata(name: "claude_status_line", documentation: "documented", maturity: "unknown", testedToolVersion: observation.claudeVersion),
            windows: windows,
            errors: errors
        )
    }

    public static func observation(fromStatusLine data: Data, observedAt: Date = Date()) throws -> ClaudeObservation {
        guard data.count <= 1_048_576 else { throw ProcessRunnerError.invalidOutput("Claude status-line input exceeds 1 MiB.") }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProcessRunnerError.invalidOutput("Claude status-line input is not an object.")
        }
        let rawRateLimits = root["rate_limits"] as? [String: Any] ?? [:]
        func parse(_ key: String) throws -> ClaudeObservation.RateLimit? {
            guard let value = rawRateLimits[key] as? [String: Any], let rawUsed = value["used_percentage"] else { return nil }
            let used = try QuotaValidation.scalar(rawUsed)
            try QuotaValidation.percentage(used)
            let reset = try value["resets_at"].flatMap { $0 is NSNull ? nil : $0 }.map { try QuotaValidation.scalar($0) }
            if let reset { try QuotaValidation.timestamp(reset) }
            return ClaudeObservation.RateLimit(usedPercentage: used, resetsAt: reset)
        }
        return ClaudeObservation(
            observedAt: observedAt,
            claudeVersion: root["version"] as? String,
            rateLimits: ClaudeObservation.RateLimits(
                fiveHour: try parse("five_hour"),
                sevenDay: try parse("seven_day"),
                spendLimit: try parse("spend_limit")
            ),
            sourceRevision: (root["session_id"] as? String).map { session in
                let duration = (root["cost"] as? [String: Any])?["total_api_duration_ms"] as? NSNumber
                return FileDigest.sha256(Data("\(session):\(duration?.stringValue ?? "unknown")".utf8))
            },
            sourceKey: (root["session_id"] as? String).map { FileDigest.sha256(Data($0.utf8)) }
        )
    }

    /// Serialize feed writers and remember each session separately, so an idle
    /// session cannot replay cached quota over a newer session's observation.
    public static func persist(_ observation: ClaudeObservation, paths: RationbookPaths) throws {
        try QuotaValidation.observation(observation)
        guard let lock = ProviderRefreshLock(provider: "claude-feed", paths: paths, wait: true) else {
            throw ClaudeIntegrationError.integrationBusy
        }
        try withExtendedLifetime(lock) {
            func read(_ url: URL) throws -> ClaudeObservation? {
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                try paths.validateFileForRead(url)
                let data = try Data(contentsOf: url)
                guard data.count <= 65_536 else { return nil }
                return try? RationbookJSON.decoder().decode(ClaudeObservation.self, from: data)
            }
            let previous = try read(paths.claudeObservation)
            let sessionFile = observation.sourceKey.map {
                paths.root.appendingPathComponent("claude-session-" + FileDigest.sha256(Data($0.utf8)) + ".json")
            }
            let sessionPrevious = try sessionFile.map { try read($0) } ?? previous
            guard observation.shouldReplace(sessionPrevious),
                  sessionPrevious == nil || observation.observedAt >= sessionPrevious!.observedAt else { return }
            let encoded = try RationbookJSON.encoder(pretty: false).encode(observation)
            if let sessionFile { try paths.atomicWrite(encoded, to: sessionFile) }
            guard previous == nil || observation.observedAt >= previous!.observedAt else { return }
            try paths.atomicWrite(encoded, to: paths.claudeObservation)
        }
    }

    private static func window(id: String, label: String, scope: String = "account", seconds: Int?, value: ClaudeObservation.RateLimit, observedAt: Date, now: Date) -> QuotaWindow {
        QuotaWindow(
            id: id,
            providerID: "claude_account",
            displayLabel: label,
            scope: scope,
            durationSeconds: seconds,
            observedAt: observedAt,
            freshness: FreshnessPolicy.classify(provider: "anthropic", observedAt: observedAt, now: now),
            usedPercent: value.usedPercentage,
            expectedResetsAt: value.resetsAt.map(Date.init(timeIntervalSince1970:)),
            dataQuality: .localObserved
        )
    }

    private func source(version: String?) -> SourceMetadata {
        SourceMetadata(name: "claude_status_line", documentation: "documented", maturity: "unknown", testedToolVersion: version)
    }
}

public struct ClaudeIntegrationRecord: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var installedAt: Date
    public var helperPath: String
    public var settingsPath: String
    public var previousStatusLine: Data?
    public var installedStatusLine: Data
    public var helperSha256: String
    public var helperVersion: String?
    public var canonicalRootPath: String

    public init(
        schemaVersion: Int,
        installedAt: Date,
        helperPath: String,
        settingsPath: String,
        previousStatusLine: Data?,
        installedStatusLine: Data,
        helperSha256: String,
        helperVersion: String? = nil,
        canonicalRootPath: String
    ) {
        self.schemaVersion = schemaVersion
        self.installedAt = installedAt
        self.helperPath = helperPath
        self.settingsPath = settingsPath
        self.previousStatusLine = previousStatusLine
        self.installedStatusLine = installedStatusLine
        self.helperSha256 = helperSha256
        self.helperVersion = helperVersion
        self.canonicalRootPath = canonicalRootPath
    }
}

public enum ClaudeIntegrationError: Error, LocalizedError {
    case signInRequired
    case unsafeSettingsPath
    case settingsChanged
    case notInstalled
    case helperMissing
    case helperChanged
    case invalidSettings
    case integrationBusy

    public var errorDescription: String? {
        switch self {
        case .signInRequired: return "Claude needs you to sign in again. Choose Sign in to Claude to reconnect your subscription."
        case .unsafeSettingsPath: return "Claude settings path is a symlink or otherwise unsafe."
        case .settingsChanged: return "Claude settings changed after Rationbook installed its helper; refusing to overwrite it."
        case .notInstalled: return "Rationbook's Claude quota feed is not installed."
        case .helperMissing: return "The Rationbook Claude helper binary was not found."
        case .helperChanged: return "The installed Rationbook Claude helper changed unexpectedly; refusing to overwrite it."
        case .invalidSettings: return "Claude settings are not a valid JSON object."
        case .integrationBusy: return "Another Rationbook process is changing the Claude integration."
        }
    }
}

enum ClaudeInstallBoundary: Equatable, Sendable {
    case pendingRecordWritten
    case helperWritten
    case settingsWritten
    case ownershipRecordWritten
}

private struct PendingClaudeIntegration: Codable {
    var schemaVersion: Int
    var intendedRecord: ClaudeIntegrationRecord
}

public struct ClaudeIntegrationManager: Sendable {
    public var paths: RationbookPaths
    public var settingsURL: URL
    var installFailureInjector: (@Sendable (ClaudeInstallBoundary) throws -> Void)?

    public init(paths: RationbookPaths = RationbookPaths(), settingsURL: URL? = nil) {
        self.paths = paths
        self.settingsURL = settingsURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        self.installFailureInjector = nil
    }

    /// Prepare the installed Claude usage launcher. Claude owns authentication;
    /// Rationbook receives only its documented status-line JSON.
    public func prepareUsageCommand(sessionID: UUID? = nil, helperSource: URL? = nil, signIn: Bool = false) throws -> URL {
        try paths.prepare()
        guard FileManager.default.fileExists(atPath: paths.claudeIntegration.path) else {
            throw ClaudeIntegrationError.notInstalled
        }
        // An app update must also update the opted-in, separately installed feed.
        if let helperSource { _ = try install(helperSource: helperSource) }
        let record = try readRecord()
        let helper = paths.binDirectory.appendingPathComponent("rationbook-claude-helper")
        try validateRecord(record, canonicalHelper: helper)
        try paths.validateFileForRead(helper)
        guard FileDigest.sha256(try Data(contentsOf: helper)) == record.helperSha256 else {
            throw ClaudeIntegrationError.helperChanged
        }
        let command = "#!/bin/sh\nset -eu\nexec " + shellQuote(helper.path) +
            " --data-root " + shellQuote(paths.root.path) + (signIn ? " --login" : " --refresh") +
            (sessionID.map { " " + $0.uuidString.lowercased() } ?? "") + "\n"
        let destination = paths.root.appendingPathComponent("Refresh Claude.command")
        try paths.atomicWrite(Data(command.utf8), to: destination, permissions: 0o700)
        return destination
    }

    /// Runs only Claude's built-in usage view; quota is read from the documented feed,
    /// never from terminal output. An unexpected login or UI state times out safely.
    public func refreshUsageAutomatically(helperSource: URL? = nil) async throws {
        guard let lock = ProviderRefreshLock(provider: "claude-usage", paths: paths) else {
            throw ClaudeIntegrationError.integrationBusy
        }
        defer { withExtendedLifetime(lock) {} }
        let sessionID = UUID()
        let sourceKey = FileDigest.sha256(Data(sessionID.uuidString.lowercased().utf8))
        let command = try prepareUsageCommand(sessionID: sessionID, helperSource: helperSource)
        let startedAt = Date()
        let child = try ManagedChildProcess(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: [command.path], terminal: true
        )
        child.standardOutput.readabilityHandler = { handle in _ = try? handle.read(upToCount: 8192) }
        defer {
            child.terminateAndReap()
            child.standardOutput.readabilityHandler = nil
            try? child.standardInput.close()
            try? child.standardOutput.close()
            try? child.standardError.close()
        }
        let started = ProcessInfo.processInfo.systemUptime
        var nextEscape: TimeInterval = 5
        while ProcessInfo.processInfo.systemUptime - started < 45 {
            try Task.checkCancellation()
            if child.wait(timeout: 0) { break }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            if elapsed >= nextEscape, nextEscape <= 20 {
                try child.standardInput.write(contentsOf: Data([0x1b]))
                nextEscape += 5
            }
            if FileManager.default.fileExists(atPath: paths.claudeObservation.path) {
                try paths.validateFileForRead(paths.claudeObservation)
                // Invalid cached content is not a reason to stop the session that can repair it.
                if let data = try? Data(contentsOf: paths.claudeObservation), data.count <= 65_536,
                   let observation = try? RationbookJSON.decoder().decode(ClaudeObservation.self, from: data),
                   observation.sourceKey == sourceKey, observation.observedAt > startedAt,
                   observation.rateLimits.fiveHour != nil || observation.rateLimits.sevenDay != nil {
                    // Never send Return into an unverified screen, including login prompts.
                    // The owned process group is closed by the deferred cleanup.
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        if requiresSignIn() { throw ClaudeIntegrationError.signInRequired }
        throw ProcessRunnerError.invalidOutput(Self.refreshFailureMessage(needsSignIn: false))
    }

    public func requiresSignIn() -> Bool {
        if let executable = try? ExecutableLocator.locate("claude"),
           let output = try? ProcessRunner.run(
               executable: executable, arguments: ["auth", "status", "--json"],
               timeout: 5, maxOutputBytes: 16_384, acceptedExitCodes: [0, 1]
           ),
           let status = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any],
           status["loggedIn"] as? Bool == false {
            return true
        }
        return false
    }

    public static func refreshFailureMessage(needsSignIn: Bool) -> String {
        if needsSignIn { return ClaudeIntegrationError.signInRequired.localizedDescription }
        return "Claude has not supplied a new quota reading. Opening Terminal alone does not refresh it: run /usage, check that subscription percentages appear, then press Esc. Previous readings are preserved."
    }

    public func runUsageSession(sessionID: UUID? = nil, signIn: Bool = false) throws -> Never {
        guard isatty(STDIN_FILENO) != 0 else {
            throw ProcessRunnerError.invalidOutput("Claude refresh needs an interactive terminal.")
        }
        let executable = try ExecutableLocator.locate("claude")
        let prepared = try ExecutableLocator.prepareForLaunch(executable)
        defer { prepared.cleanup() }
        let helper = paths.binDirectory.appendingPathComponent("rationbook-claude-helper")
        var statusLine = installedStatusLineObject(helper: helper)
        statusLine["refreshInterval"] = 1
        let settings: [String: Any] = [
            "statusLine": statusLine, "fastMode": false,
            "remoteControlAtStartup": false, "autoContinueAtUsageLimit": false,
        ]
        let settingsJSON = String(decoding: try JSONSerialization.data(withJSONObject: settings), as: UTF8.self)
        let arguments = [prepared.executableURL.path, "--setting-sources", "", "--settings", settingsJSON,
                         "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--tools", ""]
            + (sessionID.map { ["--session-id", $0.uuidString.lowercased()] } ?? []) + ["--", signIn ? "/login" : "/usage"]
        var command = "set -eu\ncd " + shellQuote(paths.root.path) +
            "\nprintf '%s\n' 'If prompted, complete Claude sign-in. Enter /usage and press Esc after subscription percentages appear. Rationbook will confirm receipt; then use /exit to close Claude.'\n"
        if let directory = prepared.cleanupDirectory {
            let cleanup = "/bin/rm -f " + shellQuote(prepared.executableURL.path) + "; /bin/rmdir " + shellQuote(directory.path)
            command += "trap " + shellQuote(cleanup) + " EXIT\ntrap 'exit 143' TERM\ntrap 'exit 130' INT\n"
        }
        command += "CLAUDE_CODE_SKIP_PROMPT_HISTORY=1 " + arguments.map(shellQuote).joined(separator: " ")
        command += "\nprintf '%s\\n' 'Claude Code has closed. Return to Rationbook to see whether a new reading was received. You can close this Terminal window.'\n"
        let argv = ["/bin/sh", "-c", command].map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        argv.withUnsafeBufferPointer { _ = execv("/bin/sh", $0.baseAddress!) }
        throw ProcessRunnerError.invalidOutput("Could not start Claude usage in this terminal.")
    }

    public func install(helperSource: URL) throws -> ClaudeIntegrationRecord {
        try paths.prepare()
        guard let integrationLock = ProviderRefreshLock(provider: "claude-integration", paths: paths, wait: true) else {
            throw ClaudeIntegrationError.integrationBusy
        }
        return try withExtendedLifetime(integrationLock) {
            try installLocked(helperSource: helperSource)
        }
    }

    private func installLocked(helperSource: URL) throws -> ClaudeIntegrationRecord {
        try validateSettingsPath()
        guard FileManager.default.isExecutableFile(atPath: helperSource.path) else { throw ClaudeIntegrationError.helperMissing }
        try recoverPendingInstall()

        if FileManager.default.fileExists(atPath: paths.claudeIntegration.path) {
            let record = try readRecord()
            let canonicalHelper = paths.binDirectory.appendingPathComponent("rationbook-claude-helper").standardizedFileURL
            try validateRecord(record, canonicalHelper: canonicalHelper)
            let currentData = try readSettingsOrEmpty()
            guard let currentSettings = try JSONSerialization.jsonObject(with: currentData) as? [String: Any] else {
                throw ClaudeIntegrationError.invalidSettings
            }
            let currentStatusLine = currentSettings["statusLine"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            guard currentStatusLine == record.installedStatusLine else { throw ClaudeIntegrationError.settingsChanged }
            let sourceData = try Data(contentsOf: helperSource, options: [.mappedIfSafe])
            let sourceHash = FileDigest.sha256(sourceData)
            if FileManager.default.fileExists(atPath: canonicalHelper.path) {
                try paths.validateFileForRead(canonicalHelper)
                let installedHash = FileDigest.sha256(try Data(contentsOf: canonicalHelper, options: [.mappedIfSafe]))
                guard installedHash == record.helperSha256 else { throw ClaudeIntegrationError.helperChanged }
            }
            let installedObject = installedStatusLineObject(helper: canonicalHelper)
            let installedData = try JSONSerialization.data(withJSONObject: installedObject, options: [.sortedKeys])
            var desiredRecord = record
            desiredRecord.schemaVersion = 3
            desiredRecord.helperPath = canonicalHelper.path
            desiredRecord.settingsPath = settingsURL.standardizedFileURL.path
            desiredRecord.installedStatusLine = installedData
            desiredRecord.helperSha256 = sourceHash
            desiredRecord.helperVersion = RationbookBuild.version
            desiredRecord.canonicalRootPath = paths.root.path
            try writePending(desiredRecord)
            try installFailureInjector?(.pendingRecordWritten)
            if !FileManager.default.fileExists(atPath: canonicalHelper.path) || record.helperSha256 != sourceHash {
                try paths.atomicWrite(sourceData, to: canonicalHelper, permissions: 0o700)
            }
            try installFailureInjector?(.helperWritten)
            if installedData != record.installedStatusLine {
                var updatedSettings = currentSettings
                updatedSettings["statusLine"] = installedObject
                try atomicSettingsWrite(
                    try JSONSerialization.data(withJSONObject: updatedSettings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                    expectedExistingData: currentData
                )
            }
            try installFailureInjector?(.settingsWritten)
            try paths.atomicWrite(try RationbookJSON.encoder(pretty: true).encode(desiredRecord), to: paths.claudeIntegration)
            try installFailureInjector?(.ownershipRecordWritten)
            try paths.removeOwnedFile(pendingRecordURL)
            return desiredRecord
        }

        let settingsExisted = FileManager.default.fileExists(atPath: settingsURL.path)
        let originalData = try readSettingsOrEmpty()
        guard var settings = try JSONSerialization.jsonObject(with: originalData) as? [String: Any] else { throw ClaudeIntegrationError.invalidSettings }
        let previous = settings["statusLine"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }

        let installedHelper = paths.binDirectory.appendingPathComponent("rationbook-claude-helper")
        let helperData = try Data(contentsOf: helperSource, options: [.mappedIfSafe])
        guard !FileManager.default.fileExists(atPath: installedHelper.path) else {
            throw ClaudeIntegrationError.helperChanged
        }
        let installedObject = installedStatusLineObject(helper: installedHelper)
        let installedData = try JSONSerialization.data(withJSONObject: installedObject, options: [.sortedKeys])
        settings["statusLine"] = installedObject
        let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])

        let record = ClaudeIntegrationRecord(
            schemaVersion: 3,
            installedAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)),
            helperPath: installedHelper.path,
            settingsPath: settingsURL.standardizedFileURL.path,
            previousStatusLine: previous,
            installedStatusLine: installedData,
            helperSha256: FileDigest.sha256(helperData),
            helperVersion: RationbookBuild.version,
            canonicalRootPath: paths.root.path
        )
        try writePending(record)
        try installFailureInjector?(.pendingRecordWritten)
        try paths.atomicWrite(helperData, to: installedHelper, permissions: 0o700)
        try installFailureInjector?(.helperWritten)
        try atomicSettingsWrite(newData, expectedExistingData: settingsExisted ? originalData : nil)
        try installFailureInjector?(.settingsWritten)
        try paths.atomicWrite(try RationbookJSON.encoder(pretty: true).encode(record), to: paths.claudeIntegration)
        try installFailureInjector?(.ownershipRecordWritten)
        try paths.removeOwnedFile(pendingRecordURL)
        return record
    }

    public func uninstall() throws {
        try paths.prepare()
        guard let integrationLock = ProviderRefreshLock(provider: "claude-integration", paths: paths, wait: true) else {
            throw ClaudeIntegrationError.integrationBusy
        }
        try withExtendedLifetime(integrationLock) { try uninstallLocked() }
    }

    private func uninstallLocked() throws {
        try recoverPendingInstall()
        guard FileManager.default.fileExists(atPath: paths.claudeIntegration.path) else { throw ClaudeIntegrationError.notInstalled }
        let record = try readRecord()
        let installedHelper = paths.binDirectory.appendingPathComponent("rationbook-claude-helper").standardizedFileURL
        try validateRecord(record, canonicalHelper: installedHelper)
        let expectedHash = record.helperSha256
        if FileManager.default.fileExists(atPath: installedHelper.path) {
            try paths.validateFileForRead(installedHelper)
            let currentHash = FileDigest.sha256(try Data(contentsOf: installedHelper, options: [.mappedIfSafe]))
            guard currentHash == expectedHash else { throw ClaudeIntegrationError.helperChanged }
        }
        try validateSettingsPath()
        let data = try Data(contentsOf: settingsURL)
        guard var settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeIntegrationError.invalidSettings }
        let current = settings["statusLine"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        guard current == record.installedStatusLine else { throw ClaudeIntegrationError.settingsChanged }

        if let previous = record.previousStatusLine {
            settings["statusLine"] = try JSONSerialization.jsonObject(with: previous)
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        try atomicSettingsWrite(
            try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
            expectedExistingData: data
        )
        if FileManager.default.fileExists(atPath: installedHelper.path) { try paths.removeOwnedFile(installedHelper) }
        try paths.removeOwnedFile(paths.claudeIntegration)
    }

    private func readRecord() throws -> ClaudeIntegrationRecord {
        try paths.validateFileForRead(paths.claudeIntegration)
        return try RationbookJSON.decoder().decode(
            ClaudeIntegrationRecord.self,
            from: Data(contentsOf: paths.claudeIntegration, options: [.mappedIfSafe])
        )
    }

    private var pendingRecordURL: URL {
        paths.root.appendingPathComponent("claude-integration.pending.json")
    }

    private func writePending(_ record: ClaudeIntegrationRecord) throws {
        let pending = PendingClaudeIntegration(schemaVersion: 1, intendedRecord: record)
        try paths.atomicWrite(try RationbookJSON.encoder(pretty: true).encode(pending), to: pendingRecordURL)
    }

    /// Finishes or rolls back an interrupted integration install using a
    /// root-confined pending ownership record. Recovery touches settings only
    /// when their statusLine is exactly the recorded baseline or intended value,
    /// and touches the helper only when its digest is authenticated.
    private func recoverPendingInstall() throws {
        guard FileManager.default.fileExists(atPath: pendingRecordURL.path) else { return }
        try paths.validateFileForRead(pendingRecordURL)
        let pending = try RationbookJSON.decoder().decode(
            PendingClaudeIntegration.self,
            from: Data(contentsOf: pendingRecordURL, options: [.mappedIfSafe])
        )
        let intended = pending.intendedRecord
        let canonicalHelper = paths.binDirectory.appendingPathComponent("rationbook-claude-helper").standardizedFileURL
        guard pending.schemaVersion == 1 else { throw ClaudeIntegrationError.helperChanged }
        try validateRecord(intended, canonicalHelper: canonicalHelper)
        let intendedHash = intended.helperSha256

        let currentRecord: ClaudeIntegrationRecord?
        if FileManager.default.fileExists(atPath: paths.claudeIntegration.path) {
            currentRecord = try readRecord()
            try validateRecord(currentRecord!, canonicalHelper: canonicalHelper)
        } else {
            currentRecord = nil
        }

        let helperHash: String?
        if FileManager.default.fileExists(atPath: canonicalHelper.path) {
            try paths.validateFileForRead(canonicalHelper)
            helperHash = FileDigest.sha256(try Data(contentsOf: canonicalHelper, options: [.mappedIfSafe]))
        } else {
            helperHash = nil
        }
        let settingsData = try readSettingsOrEmpty()
        guard let settings = try JSONSerialization.jsonObject(with: settingsData) as? [String: Any] else {
            throw ClaudeIntegrationError.invalidSettings
        }
        let currentStatusLine = settings["statusLine"].flatMap {
            try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])
        }
        let baselineStatusLine = currentRecord?.installedStatusLine ?? intended.previousStatusLine

        if helperHash == intendedHash,
           currentStatusLine == intended.installedStatusLine || currentStatusLine == baselineStatusLine {
            if currentStatusLine != intended.installedStatusLine {
                try replaceStatusLine(in: settingsData, with: intended.installedStatusLine)
            }
            try paths.atomicWrite(try RationbookJSON.encoder(pretty: true).encode(intended), to: paths.claudeIntegration)
            try paths.removeOwnedFile(pendingRecordURL)
            return
        }

        if let currentRecord,
           helperHash == currentRecord.helperSha256,
           currentStatusLine == currentRecord.installedStatusLine {
            try paths.removeOwnedFile(pendingRecordURL)
            return
        }

        guard currentRecord == nil else { throw ClaudeIntegrationError.helperChanged }
        if helperHash == nil {
            if currentStatusLine == intended.installedStatusLine {
                try replaceStatusLine(in: settingsData, with: intended.previousStatusLine)
            } else if currentStatusLine != baselineStatusLine {
                throw ClaudeIntegrationError.settingsChanged
            }
            try paths.removeOwnedFile(pendingRecordURL)
            return
        }
        guard helperHash == intendedHash else { throw ClaudeIntegrationError.helperChanged }
        // A user edit after the interrupted write is preserved; the helper is
        // still safe to remove because the pending record authenticates it.
        try paths.removeOwnedFile(canonicalHelper)
        try paths.removeOwnedFile(pendingRecordURL)
    }

    private func replaceStatusLine(in currentData: Data, with encodedStatusLine: Data?) throws {
        guard var settings = try JSONSerialization.jsonObject(with: currentData) as? [String: Any] else {
            throw ClaudeIntegrationError.invalidSettings
        }
        if let encodedStatusLine {
            settings["statusLine"] = try JSONSerialization.jsonObject(with: encodedStatusLine)
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        try atomicSettingsWrite(
            try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
            expectedExistingData: FileManager.default.fileExists(atPath: settingsURL.path) ? currentData : nil
        )
    }

    private func validateRecord(_ record: ClaudeIntegrationRecord, canonicalHelper: URL) throws {
        guard record.schemaVersion == 3,
              URL(fileURLWithPath: record.helperPath).standardizedFileURL == canonicalHelper,
              URL(fileURLWithPath: record.settingsPath).standardizedFileURL == settingsURL.standardizedFileURL,
              record.canonicalRootPath == paths.root.path else {
            throw ClaudeIntegrationError.helperChanged
        }
    }

    private func installedStatusLineObject(helper: URL) -> [String: Any] {
        [
            "type": "command",
            "command": "\(shellQuote(helper.path)) --data-root \(shellQuote(paths.root.path))",
        ]
    }

    private func readSettingsOrEmpty() throws -> Data {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return Data("{}".utf8) }
        try validateSettingsPath()
        return try Data(contentsOf: settingsURL, options: [.mappedIfSafe])
    }

    private func validateSettingsPath() throws {
        do {
            try FileTrust.createDirectory(settingsURL.deletingLastPathComponent())
            if FileManager.default.fileExists(atPath: settingsURL.path) {
                try FileTrust.rejectMutationACL(settingsURL)
            }
        } catch {
            throw ClaudeIntegrationError.unsafeSettingsPath
        }
        var current = settingsURL.standardizedFileURL
        while current.path != "/" {
            var status = stat()
            if lstat(current.path, &status) == 0 {
                if status.st_mode & S_IFMT == S_IFLNK,
                   !["/var", "/tmp", "/etc"].contains(current.path) {
                    throw ClaudeIntegrationError.unsafeSettingsPath
                }
                if current == settingsURL.standardizedFileURL {
                    guard status.st_mode & S_IFMT == S_IFREG,
                          status.st_uid == geteuid(),
                          status.st_mode & 0o022 == 0 else {
                        throw ClaudeIntegrationError.unsafeSettingsPath
                    }
                }
            }
            current.deleteLastPathComponent()
        }
        var parentStatus = stat()
        guard lstat(settingsURL.deletingLastPathComponent().path, &parentStatus) == 0,
              parentStatus.st_mode & S_IFMT == S_IFDIR,
              parentStatus.st_uid == geteuid(),
              parentStatus.st_mode & 0o022 == 0 else {
            throw ClaudeIntegrationError.unsafeSettingsPath
        }
    }

    private func atomicSettingsWrite(_ data: Data, expectedExistingData: Data?) throws {
        try validateSettingsPath()
        let currentExists = FileManager.default.fileExists(atPath: settingsURL.path)
        let currentData = currentExists ? try Data(contentsOf: settingsURL) : nil
        guard currentData == expectedExistingData else { throw ClaudeIntegrationError.settingsChanged }
        let temporary = settingsURL.deletingLastPathComponent().appendingPathComponent(".settings.\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ClaudeIntegrationError.unsafeSettingsPath }
        var removeTemporary = true
        defer {
            close(descriptor)
            if removeTemporary { try? FileManager.default.removeItem(at: temporary) }
        }
        try data.withUnsafeBytes { rawBuffer in
            var remaining = rawBuffer.count
            var cursor = rawBuffer.baseAddress
            while remaining > 0 {
                let count = write(descriptor, cursor, remaining)
                guard count > 0 else { throw ClaudeIntegrationError.unsafeSettingsPath }
                remaining -= count
                cursor = cursor?.advanced(by: count)
            }
        }
        guard fchmod(descriptor, 0o600) == 0, fsync(descriptor) == 0 else {
            throw ClaudeIntegrationError.unsafeSettingsPath
        }
        try validateSettingsPath()
        let rechecked = FileManager.default.fileExists(atPath: settingsURL.path) ? try Data(contentsOf: settingsURL) : nil
        guard rechecked == expectedExistingData else { throw ClaudeIntegrationError.settingsChanged }
        guard rename(temporary.path, settingsURL.path) == 0 else { throw ClaudeIntegrationError.unsafeSettingsPath }
        removeTemporary = false
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

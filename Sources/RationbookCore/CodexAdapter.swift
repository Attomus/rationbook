// SPDX-License-Identifier: Apache-2.0

import Foundation

private final class AppServerResponseState: @unchecked Sendable {
    private let maximumBytes = 1_048_576
    private let lock = NSLock()
    private var buffer = Data()
    private var response: [String: Any]?
    private var parseError: Error?
    private var signaled = false

    func consume(_ data: Data, signal: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard buffer.count + data.count <= maximumBytes else {
            parseError = ProcessRunnerError.invalidOutput("Codex app-server output exceeded 1 MiB.")
            if !signaled { signaled = true; signal() }
            return
        }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            do {
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                // Request id 2 is reserved below for account/rateLimits/read; notifications and initialize replies are ignored.
                if Self.integer(object["id"]) == 2 {
                    if let error = object["error"] as? [String: Any] {
                        parseError = ProcessRunnerError.invalidOutput(error["message"] as? String ?? "Codex app-server error")
                    } else {
                        response = object["result"] as? [String: Any]
                    }
                    if !signaled {
                        signaled = true
                        signal()
                    }
                }
            } catch {
                parseError = error
            }
        }
    }

    func result() throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        if let parseError { throw parseError }
        guard let response else { throw ProcessRunnerError.invalidOutput("Missing rate-limit result.") }
        return response
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }
}

public struct CodexAdapter: ProviderAdapter {
    public let providerID = "openai"
    private static let maximumRateLimitBuckets = 64
    // Far above every known provider window, but small enough that converting
    // minutes to seconds remains useful to consumers and cannot overflow.
    private static let maximumWindowDurationMinutes = 10 * 366 * 24 * 60
    private static let implementedCapabilities = AdapterCapabilities(
        supportsOnDemandRefresh: true,
        supportsPushUpdates: false,
        supportsAccountScope: true,
        supportsModelScope: false
    )
    public var capabilities: AdapterCapabilities { Self.implementedCapabilities }
    public var agentLabel: String

    public init(agentLabel: String = "OpenAI") {
        self.agentLabel = agentLabel
    }

    public func detect() -> ProviderStatus {
        do {
            let executable = try ExecutableLocator.locate("codex")
            let version = ProcessRunner.version(executable: executable)
            return ProviderStatus(
                provider: providerID,
                agentLabel: agentLabel,
                state: .waitingForObservation,
                capabilities: capabilities,
                source: source(version: version),
                errors: [StructuredError(code: "not_refreshed", message: "Codex is installed; refresh to read quota.")]
            )
        } catch {
            return ProviderErrorMapper.status(provider: providerID, agentLabel: agentLabel, capabilities: capabilities, source: source(version: nil), error: error)
        }
    }

    public func fetch(now: Date = Date()) throws -> ProviderStatus {
        let executable = try ExecutableLocator.locate("codex")
        let version = ProcessRunner.version(executable: executable)
        let result = try Self.requestRateLimits(executable: executable, timeout: 5)
        return try Self.parseRateLimits(result, observedAt: now, agentLabel: agentLabel, version: version)
    }

    public static func parseRateLimits(
        _ result: [String: Any],
        observedAt: Date,
        agentLabel: String = "OpenAI",
        version: String? = nil
    ) throws -> ProviderStatus {
        var buckets: [[String: Any]] = []
        if let byID = result["rateLimitsByLimitId"] as? [String: Any] {
            guard byID.count <= maximumRateLimitBuckets else {
                throw ProcessRunnerError.invalidOutput("Codex returned too many rate-limit buckets.")
            }
            buckets = byID.keys.sorted().compactMap { byID[$0] as? [String: Any] }
        } else if let one = result["rateLimits"] as? [String: Any] {
            buckets = [one]
        }

        var windows: [QuotaWindow] = []
        var plan: String?
        for bucket in buckets {
            let limitID = bucket["limitId"] as? String ?? "unknown"
            let limitName = bucket["limitName"] as? String
            plan = plan ?? bucket["planType"] as? String
            // Position is part of identity only; Rationbook never assigns undocumented semantics to primary/secondary.
            for (position, key) in ["primary", "secondary"].enumerated() {
                guard let raw = bucket[key] as? [String: Any], let rawUsed = raw["usedPercent"] else { continue }
                let used = try QuotaValidation.scalar(rawUsed)
                let durationMinutes = validDurationMinutes(raw["windowDurationMins"])
                let durationSeconds = durationMinutes.map { $0 * 60 }
                let reset = try raw["resetsAt"].flatMap { $0 is NSNull ? nil : $0 }.map {
                    Date(timeIntervalSince1970: try QuotaValidation.scalar($0))
                }
                let label = limitName ?? durationMinutes.map(Self.durationLabel) ?? "Quota window"
                windows.append(QuotaWindow(
                    id: "openai:\(limitID):\(position):\(durationMinutes ?? 0)",
                    providerID: limitID,
                    providerLabel: limitName,
                    displayLabel: label,
                    durationSeconds: durationSeconds,
                    observedAt: observedAt,
                    freshness: .fresh,
                    usedPercent: used,
                    expectedResetsAt: reset,
                    dataQuality: .authoritative
                ))
            }
        }

        guard !windows.isEmpty else {
            throw ProcessRunnerError.invalidOutput("Codex returned no quota windows.")
        }
        try QuotaValidation.windows(windows)
        if let plan { try QuotaValidation.text(plan) }
        return ProviderStatus(
            provider: "openai",
            agentLabel: agentLabel,
            state: .available,
            account: ProviderAccount(plan: plan),
            capabilities: Self.implementedCapabilities,
            source: SourceMetadata(name: "codex_app_server", documentation: "documented", maturity: "experimental", testedToolVersion: version),
            windows: windows
        )
    }

    private static func requestRateLimits(executable: URL, timeout: TimeInterval) throws -> [String: Any] {
        let process = try ManagedChildProcess(executable: executable, arguments: ["app-server"])
        defer { process.terminateAndReap() }

        let state = AppServerResponseState()
        let semaphore = DispatchSemaphore(value: 0)
        process.standardOutput.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            state.consume(data) { semaphore.signal() }
        }
        process.standardError.readabilityHandler = { handle in
            _ = handle.availableData
        }

        let messages: [[String: Any]] = [
            ["method": "initialize", "id": 1, "params": ["clientInfo": ["name": "rationbook", "title": "Rationbook", "version": RationbookBuild.version]]],
            ["method": "initialized", "params": [:]],
            ["method": "account/rateLimits/read", "id": 2, "params": [:]],
        ]
        for message in messages {
            var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
            data.append(0x0A)
            try process.standardInput.write(contentsOf: data)
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.standardOutput.readabilityHandler = nil
            process.standardError.readabilityHandler = nil
            try? process.standardInput.close()
            process.terminateAndReap()
            throw ProcessRunnerError.timedOut("codex app-server")
        }
        process.standardOutput.readabilityHandler = nil
        process.standardError.readabilityHandler = nil
        try? process.standardInput.close()
        process.terminateAndReap()
        return try state.result()
    }

    private func source(version: String?) -> SourceMetadata {
        SourceMetadata(name: "codex_app_server", documentation: "documented", maturity: "experimental", testedToolVersion: version)
    }

    private static func durationLabel(_ minutes: Int) -> String {
        if minutes % 10_080 == 0 { return "\(minutes / 10_080) week" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440) day" }
        if minutes % 60 == 0 { return "\(minutes / 60) hour" }
        return "\(minutes) min"
    }

    private static func validDurationMinutes(_ value: Any?) -> Int? {
        guard let value else { return nil }
        let raw: Double
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            raw = number.doubleValue
        } else if let number = value as? Double {
            raw = number
        } else if let number = value as? Int {
            return (1...maximumWindowDurationMinutes).contains(number) ? number : nil
        } else {
            return nil
        }
        guard raw.isFinite,
              raw.rounded(.towardZero) == raw,
              raw >= 1,
              raw <= Double(maximumWindowDurationMinutes) else {
            return nil
        }
        return Int(raw)
    }
}

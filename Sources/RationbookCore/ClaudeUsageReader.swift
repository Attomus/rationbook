// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

/// Queries the installed CLI. Authentication and network requests remain in Claude Code.
/// No user message or model prompt is sent through this protocol.
struct ClaudeUsageReader {
    struct Reading: Codable {
        var observation: ClaudeObservation
        var modelWindows: [QuotaWindow]
    }

    static func read(executable: URL, timeout: TimeInterval = 40) async throws -> Reading {
        try Task.checkCancellation()
        let requestID = UUID().uuidString
        let child = try ManagedChildProcess(executable: executable, arguments: [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--safe-mode", "--no-chrome", "--disable-slash-commands", "--strict-mcp-config",
            "--mcp-config", "{\"mcpServers\":{}}", "--tools", "", "--no-session-persistence",
            "--settings", "{\"fastMode\":false,\"disableAllHooks\":true}",
        ], environmentOverrides: ["CLAUDE_CODE_DISABLE_FAST_MODE": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"])
        defer {
            child.terminateAndReap()
            try? child.standardInput.close()
            try? child.standardOutput.close()
            try? child.standardError.close()
        }
        for handle in [child.standardOutput, child.standardError] {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw ProcessRunnerError.invalidOutput("Could not configure Claude usage output.")
            }
        }
        let request: [String: Any] = ["type": "control_request", "request_id": requestID,
                                    "request": ["subtype": "get_usage", "skip_behaviors": true]]
        var input = try JSONSerialization.data(withJSONObject: request)
        input.append(0x0a)
        try Task.checkCancellation()
        try child.standardInput.write(contentsOf: input)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var buffer = Data()
        var total = 0
        var bytes = [UInt8](repeating: 0, count: 8192)
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            for handle in [child.standardOutput, child.standardError] {
                let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
                if count < 0, errno != EAGAIN, errno != EINTR {
                    throw ProcessRunnerError.invalidOutput("Could not read Claude usage output.")
                }
                if count > 0 {
                    total += count
                    guard total <= 1_048_576 else { throw ProcessRunnerError.invalidOutput("Claude usage output exceeds 1 MiB.") }
                    if handle === child.standardOutput { buffer.append(contentsOf: bytes.prefix(count)) }
                }
            }
            while let end = buffer.firstIndex(of: 0x0a) {
                let line = Data(buffer.prefix(upTo: end))
                buffer.removeSubrange(...end)
                if line.isEmpty { continue }
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                      message["type"] as? String == "control_response",
                      let response = message["response"] as? [String: Any],
                      response["request_id"] as? String == requestID else { continue }
                guard response["subtype"] as? String == "success",
                      let payload = response["response"] as? [String: Any] else {
                    throw ProcessRunnerError.invalidOutput("Claude Code could not provide usage. Update Claude Code and try again.")
                }
                return try parse(payload, now: Date())
            }
            if child.wait(timeout: 0) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ProcessRunnerError.timedOut("Claude usage")
    }

    static func parse(_ payload: [String: Any], now: Date) throws -> Reading {
        guard payload["rate_limits_available"] as? Bool == true,
              let limits = payload["rate_limits"] as? [String: Any] else {
            throw ProcessRunnerError.invalidOutput("Claude Code has not supplied subscription limits. Check your Claude sign-in and retry.")
        }
        func limit(_ raw: Any?) throws -> ClaudeObservation.RateLimit? {
            guard let raw, !(raw is NSNull) else { return nil }
            guard let value = raw as? [String: Any], let used = value["utilization"] else {
                throw ProcessRunnerError.invalidOutput("Unrecognised Claude usage window.")
            }
            let percent = try QuotaValidation.scalar(used)
            try QuotaValidation.percentage(percent)
            var reset: Double?
            if let rawReset = value["resets_at"], !(rawReset is NSNull) {
                guard let text = rawReset as? String else { throw ProcessRunnerError.invalidOutput("Invalid Claude reset time.") }
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let precise = formatter.date(from: text)
                formatter.formatOptions = [.withInternetDateTime]
                guard let date = precise ?? formatter.date(from: text) else { throw ProcessRunnerError.invalidOutput("Invalid Claude reset time.") }
                reset = date.timeIntervalSince1970
                try QuotaValidation.timestamp(reset!)
            }
            return .init(usedPercentage: percent, resetsAt: reset)
        }
        let observation = ClaudeObservation(observedAt: now, claudeVersion: nil,
            rateLimits: .init(fiveHour: try limit(limits["five_hour"]), sevenDay: try limit(limits["seven_day"])),
            sourceRevision: UUID().uuidString)
        guard observation.rateLimits.fiveHour != nil || observation.rateLimits.sevenDay != nil else {
            throw ProcessRunnerError.invalidOutput("Claude supplied no current account quota. Previous readings are preserved.")
        }
        var models: [String: (String, ClaudeObservation.RateLimit)] = [:]
        func add(_ name: String, _ value: ClaudeObservation.RateLimit) throws {
            try QuotaValidation.text(name, maximum: 80)
            let key = name.lowercased().replacingOccurrences(of: "claude ", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { throw ProcessRunnerError.invalidOutput("Missing Claude model name.") }
            models[key] = (name, value)
        }
        for family in ["fable", "opus", "sonnet", "haiku"] {
            if let value = try limit(limits["seven_day_" + family]) { try add(family.capitalized, value) }
        }
        if let scoped = limits["model_scoped"], !(scoped is NSNull) {
            guard let rows = scoped as? [[String: Any]], rows.count <= 16 else {
                throw ProcessRunnerError.invalidOutput("Invalid Claude model usage list.")
            }
            for row in rows {
                guard let name = row["display_name"] as? String, let value = try limit(row) else {
                    throw ProcessRunnerError.invalidOutput("Invalid Claude model usage.")
                }
                try add(name, value)
            }
        }
        let windows = models.sorted { $0.key < $1.key }.map { key, entry in
            QuotaWindow(id: "anthropic:model:" + key + ":604800", providerID: key,
                providerLabel: entry.0, displayLabel: entry.0 + " weekly", scope: "model", model: entry.0,
                durationSeconds: 604_800, observedAt: now, freshness: .fresh,
                usedPercent: entry.1.usedPercentage,
                expectedResetsAt: entry.1.resetsAt.map(Date.init(timeIntervalSince1970:)), dataQuality: .localObserved)
        }
        try QuotaValidation.windows(windows)
        return Reading(observation: observation, modelWindows: windows)
    }
}

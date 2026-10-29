// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import RationbookCore

enum CLIExit: Int32 {
    case success = 0
    case noProviderState = 2
    case usage = 64
    case software = 70
}

func printUsage() {
    print("""
    Rationbook — local Codex and Claude quota capacity

    Usage:
      rationbook status [--json] [--refresh]
      rationbook history [--json] [--limit N]
      rationbook forecast [--json] [--refresh]
      rationbook doctor [--json]
      rationbook diagnostics [--json]
      rationbook claude install-feed [--helper PATH]
      rationbook claude refresh [--automatic]
      rationbook claude uninstall-feed
      rationbook supplement import < observation.json
      rationbook supplement status [--json]
      rationbook supplement remove
      rationbook install-cli
      rationbook uninstall
      rationbook version
    """)
}

func encode<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try RationbookJSON.encoder(pretty: true).encode(value), as: UTF8.self)
}

func ageDescription(_ date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3_600 { return "\(seconds / 60)m" }
    return "\(seconds / 3_600)h"
}

func humanStatus(_ envelope: StatusEnvelope) -> String {
    var lines = ["RATIONBOOK", ""]
    for provider in envelope.providers {
        let scope = provider.provider == "anthropic" ? "CLAUDE AGGREGATE" : "CODEX"
        lines.append("\(provider.agentLabel.uppercased()) / \(scope)  [\(provider.state.rawValue)]")
        if provider.windows.isEmpty {
            lines.append("  \(provider.errors.first?.message ?? "No quota windows available")")
        }
        for window in provider.windows {
            let remaining = String(format: "%.1f%% remaining", window.remainingPercent)
            let safe = window.policy.map { String(format: "%.1f%% safe", $0.safeRemainingPercent) } ?? "policy unavailable"
            let reset = window.expectedResetsAt.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "reset unknown"
            lines.append("  \(window.displayLabel): \(remaining) · \(safe)")
            lines.append("    resets \(reset) · \(window.freshness.rawValue) · observed \(ageDescription(window.observedAt)) ago")
            if let rate = window.observedRate {
                lines.append("    usage rate \(String(format: "%+.1f", rate.netChangePPPerWallHour))%/h (\(rate.confidence.rawValue) confidence, n=\(rate.sampleCount))")
            }
            if let scenario = window.reserveScenario {
                lines.append("    continuation: \(String(format: "%.1f", scenario.hoursUntilReserve))h to reserve; \(scenario.firstEvent.replacingOccurrences(of: "_", with: " ")) first")
            }
        }
        lines.append("")
    }
    return lines.joined(separator: "\n")
}

func humanForecast(_ envelope: ForecastEnvelope) -> String {
    var lines = ["RATIONBOOK FORECAST", ""]
    if envelope.windows.isEmpty { lines.append("No aggregate quota windows are available.") }
    for window in envelope.windows {
        lines.append("\(window.provider.uppercased()) / \(window.displayLabel)")
        if let scenario = window.scenario {
            lines.append("  \(String(format: "%.1f", scenario.hoursUntilReserve))h to reserve · \(scenario.firstEvent.replacingOccurrences(of: "_", with: " ")) first · \(scenario.confidence.rawValue) confidence")
        } else {
            lines.append("  unavailable: \((window.unavailableReason ?? "unknown").replacingOccurrences(of: "_", with: " "))")
        }
    }
    return lines.joined(separator: "\n")
}

func runningExecutableURL() throws -> URL {
    guard let executable = Bundle.main.executableURL else { throw ClaudeIntegrationError.helperMissing }
    return executable.resolvingSymlinksInPath()
}

func helperURL(arguments: [String]) throws -> URL {
    if let index = arguments.firstIndex(of: "--helper"), arguments.indices.contains(index + 1) {
        return URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
    }
    let executable = try runningExecutableURL()
    let sibling = executable.deletingLastPathComponent().appendingPathComponent("rationbook-claude-helper")
    if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
    if let override = ProcessInfo.processInfo.environment["RATIONBOOK_HELPER_PATH"] {
        return URL(fileURLWithPath: override)
    }
    throw ClaudeIntegrationError.helperMissing
}

func rejectUnknownOptions(_ arguments: [String], allowed: Set<String>) {
    for argument in arguments.dropFirst() where argument.hasPrefix("--") && !allowed.contains(argument) {
        FileHandle.standardError.write(Data("rationbook: unknown option \(argument)\n".utf8))
        exit(CLIExit.usage.rawValue)
    }
}

func boundedStandardInput(limit: Int) throws -> Data {
    var data = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: min(8_192, limit + 1 - data.count)), !chunk.isEmpty {
        data.append(chunk)
        if data.count > limit { throw ModelCapacitySupplementError.tooLarge }
    }
    return data
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    printUsage()
    exit(CLIExit.usage.rawValue)
}

do {
    switch command {
    case "status":
        rejectUnknownOptions(arguments, allowed: ["--json", "--refresh"])
        let service = try RationbookService()
        let envelope = service.status(refresh: arguments.contains("--refresh"))
        if arguments.contains("--json") { print(try encode(envelope)) }
        else { print(humanStatus(envelope)) }
        if envelope.overallState == .unavailable { exit(CLIExit.noProviderState.rawValue) }

    case "forecast":
        rejectUnknownOptions(arguments, allowed: ["--json", "--refresh"])
        let service = try RationbookService()
        let forecast = service.forecast(refresh: arguments.contains("--refresh"))
        if arguments.contains("--json") { print(try encode(forecast)) }
        else { print(humanForecast(forecast)) }

    case "history":
        rejectUnknownOptions(arguments, allowed: ["--json", "--limit"])
        let service = try RationbookService()
        let limit: Int = {
            guard let index = arguments.firstIndex(of: "--limit"), arguments.indices.contains(index + 1) else { return 100 }
            return Int(arguments[index + 1]) ?? -1
        }()
        guard limit > 0 else { printUsage(); exit(CLIExit.usage.rawValue) }
        let rows = try service.history(limit: limit)
        if arguments.contains("--json") {
            print(try encode(HistoryEnvelope(generatedAt: Date(), samples: rows)))
        } else {
            for row in rows {
                print("\(row.provider) \(row.windowID) \(String(format: "%.2f", row.usedPercent))% used · \(ageDescription(row.lastObservedAt)) ago · n=\(row.sampleCount)")
            }
        }

    case "doctor":
        rejectUnknownOptions(arguments, allowed: ["--json"])
        let report = try RationbookService().doctor()
        if arguments.contains("--json") { print(try encode(report)) }
        else {
            print("RATIONBOOK DOCTOR\n")
            for check in report.checks { print("\(check.name): \(check.status)\n  \(check.detail)") }
        }

    case "diagnostics":
        rejectUnknownOptions(arguments, allowed: ["--json"])
        let report = RationbookDiagnostics.report(from: try RationbookService().doctor())
        if arguments.contains("--json") { print(try encode(report)) }
        else {
            print("RATIONBOOK DIAGNOSTICS\n")
            print("Version: \(report.appVersion) (\(report.appBuild))")
            print("System: \(report.operatingSystem) · \(report.architecture)\n")
            for check in report.checks { print("\(check.name): \(check.status)\n  \(check.detail)") }
        }

    case "claude":
        guard arguments.count >= 2 else { printUsage(); exit(CLIExit.usage.rawValue) }
        let manager = ClaudeIntegrationManager()
        if arguments[1] == "install-feed" {
            _ = try manager.install(helperSource: helperURL(arguments: arguments))
            print("Claude aggregate quota feed installed.")
        } else if arguments[1] == "refresh", arguments.dropFirst(2) == ["--automatic"] {
            try await manager.refreshUsageAutomatically(helperSource: helperURL(arguments: arguments))
            print("Claude usage updated.")
        } else if arguments[1] == "refresh" {
            guard arguments.count == 2 else { printUsage(); exit(CLIExit.usage.rawValue) }
            guard isatty(STDIN_FILENO) != 0 else {
                throw ProcessRunnerError.invalidOutput("Claude refresh needs an interactive terminal; it does not run in the background.")
            }
            let command = try manager.prepareUsageCommand(helperSource: helperURL(arguments: arguments))
            // Replace this process so Claude keeps the foreground terminal group.
            let arguments = ["/bin/sh", command.path].map { strdup($0) } + [nil]
            defer { arguments.forEach { free($0) } }
            arguments.withUnsafeBufferPointer { buffer in
                _ = execv("/bin/sh", buffer.baseAddress!)
            }
            throw ProcessRunnerError.invalidOutput("Could not start Claude usage in this terminal.")
        } else if arguments[1] == "uninstall-feed" {
            try manager.uninstall()
            print("Claude quota feed removed and previous status line restored.")
        } else {
            printUsage(); exit(CLIExit.usage.rawValue)
        }

    case "supplement":
        guard arguments.count >= 2 else { printUsage(); exit(CLIExit.usage.rawValue) }
        let manager = ModelCapacitySupplementManager()
        switch arguments[1] {
        case "import":
            rejectUnknownOptions(arguments, allowed: [])
            let supplement = try manager.importData(
                boundedStandardInput(limit: ModelCapacitySupplementManager.maximumBytes)
            )
            print("Imported \(supplement.windows.count) local model-capacity window(s) for \(supplement.provider).")
        case "status":
            rejectUnknownOptions(arguments, allowed: ["--json"])
            if let supplement = try manager.load() {
                if arguments.contains("--json") { print(try encode(supplement)) }
                else {
                    print("Local model-capacity supplement: \(supplement.windows.count) window(s), observed \(ageDescription(supplement.observedAt)) ago.")
                }
            } else {
                print(arguments.contains("--json") ? "null" : "No local model-capacity supplement is installed.")
            }
        case "remove":
            rejectUnknownOptions(arguments, allowed: [])
            try manager.remove()
            print("Removed the local model-capacity supplement.")
        default:
            printUsage(); exit(CLIExit.usage.rawValue)
        }

    case "install-cli":
        rejectUnknownOptions(arguments, allowed: [])
        let source = try runningExecutableURL()
        let record = try CLIIntegrationManager().install(source: source)
        print("Installed \(record.symlinkPath) -> \(record.executablePath)")
        let localBin = URL(fileURLWithPath: record.symlinkPath).deletingLastPathComponent().standardizedFileURL.path
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        if !pathEntries.contains(localBin) {
            let shellName = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh").lastPathComponent
            let profile = shellName == "bash" ? "~/.bash_profile" : "~/.zshrc"
            print("Add Rationbook to PATH for future shells:\n  echo 'export PATH=\"$HOME/.local/bin:$PATH\"' >> \(profile)")
        }

    case "uninstall":
        rejectUnknownOptions(arguments, allowed: [])
        let paths = RationbookPaths()
        var removedAnything = false
        if FileManager.default.fileExists(atPath: paths.claudeIntegration.path) {
            try ClaudeIntegrationManager(paths: paths).uninstall()
            removedAnything = true
        }
        if FileManager.default.fileExists(atPath: paths.cliIntegration.path) {
            try CLIIntegrationManager(paths: paths).uninstall()
            removedAnything = true
        }
        print(removedAnything ? "Removed installed Rationbook integrations." : "Rationbook integrations were already absent.")

    case "version", "--version", "-v":
        print("rationbook \(RationbookBuild.version) (\(RationbookBuild.build))")

    case "help", "--help", "-h":
        printUsage()

    default:
        printUsage()
        exit(CLIExit.usage.rawValue)
    }
} catch {
    FileHandle.standardError.write(Data("rationbook: \(error.localizedDescription)\n".utf8))
    exit(CLIExit.software.rawValue)
}

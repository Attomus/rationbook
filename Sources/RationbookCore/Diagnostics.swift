// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum RationbookBuild {
    public static let version = "0.1.2"
    public static let build = "4"
}

public struct RationbookDiagnosticReport: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var generatedAt: Date
    public var appVersion: String
    public var appBuild: String
    public var operatingSystem: String
    public var architecture: String
    public var checks: [DoctorCheck]

    public init(
        schemaVersion: Int = 1,
        generatedAt: Date = Date(),
        appVersion: String,
        appBuild: String,
        operatingSystem: String,
        architecture: String,
        checks: [DoctorCheck]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.checks = checks
    }
}

public enum RationbookDiagnostics {
    public static func report(
        from doctor: DoctorReport,
        appVersion: String = RationbookBuild.version,
        appBuild: String = RationbookBuild.build,
        operatingSystem: String = ProcessInfo.processInfo.operatingSystemVersionString,
        architecture: String = currentArchitecture,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> RationbookDiagnosticReport {
        RationbookDiagnosticReport(
            generatedAt: doctor.generatedAt,
            appVersion: appVersion,
            appBuild: appBuild,
            operatingSystem: sanitized(operatingSystem, homeDirectory: homeDirectory),
            architecture: sanitized(architecture, homeDirectory: homeDirectory),
            checks: doctor.checks.map {
                DoctorCheck(
                    name: sanitized($0.name, homeDirectory: homeDirectory),
                    status: sanitized($0.status, homeDirectory: homeDirectory),
                    detail: sanitized($0.detail, homeDirectory: homeDirectory)
                )
            }
        )
    }

    public static func sanitized(_ value: String, homeDirectory: String) -> String {
        let withoutHome = homeDirectory.isEmpty ? value : value.replacingOccurrences(of: homeDirectory, with: "~")
        var singleLine = withoutHome
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let redactions: [(String, String)] = [
            (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "<redacted-email>"),
            (#"(?i)Bearer\s+[^\s]+"#, "Bearer <redacted>"),
            (#"(?i)(access|refresh|api)[_-]?token\s*[:=]\s*[^\s,;]+"#, "$1_token=<redacted>"),
        ]
        for (pattern, replacement) in redactions {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(singleLine.startIndex..., in: singleLine)
            singleLine = expression.stringByReplacingMatches(in: singleLine, range: range, withTemplate: replacement)
        }
        return String(singleLine.prefix(512))
    }

    public static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

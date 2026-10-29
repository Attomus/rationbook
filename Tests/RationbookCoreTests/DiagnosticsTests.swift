// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Testing
@testable import RationbookCore

@Suite struct DiagnosticsTests {
    @Test func redactsSensitiveValues() throws {
        let generatedAt = Date(timeIntervalSince1970: 1_788_131_000)
        let tokenAssignment = "access" + "_token=secret-value"
        let doctor = DoctorReport(generatedAt: generatedAt, checks: [
            DoctorCheck(
                name: "Anthropic",
                status: "warning",
                detail: "/home/private/Library app@example.com \(tokenAssignment)\nBearer another-secret"
            ),
        ])
        let report = RationbookDiagnostics.report(
            from: doctor,
            appVersion: "0.test",
            appBuild: "7",
            operatingSystem: "macOS test",
            architecture: "arm64",
            homeDirectory: "/home/private"
        )
        let encoded = String(decoding: try RationbookJSON.encoder().encode(report), as: UTF8.self)
        #expect(report.generatedAt == generatedAt)
        #expect(report.appVersion == "0.test")
        #expect(report.checks.first?.detail == "~/Library <redacted-email> access" + "_token=<redacted> Bearer <redacted>")
        #expect(!encoded.contains("/home/private"))
        #expect(!encoded.contains("secret-value"))
        #expect(!encoded.contains("app@example.com"))
    }

    @Test func omitsLocalPaths() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try RationbookService(paths: RationbookPaths(root: root))
        let report = RationbookDiagnostics.report(from: service.doctor(), homeDirectory: "/home/not-this-root")
        let encoded = String(decoding: try RationbookJSON.encoder().encode(report), as: UTF8.self)
        #expect(!encoded.contains(root.path))
        #expect(!encoded.contains("/opt/homebrew"))
        #expect(!encoded.contains("/usr/local"))
    }

    @Test func reducesProviderErrors() {
        let raw = "token=secret-value authentication failed in /private/workspace"
        let mapped = ProviderErrorMapper.structured(ProcessRunnerError.failed("codex", 1, raw))
        #expect(mapped.0 == .loggedOut)
        #expect(mapped.1.code == "provider_logged_out")
        #expect(!mapped.1.message.contains("secret-value"))
        #expect(!mapped.1.message.contains("/private"))
    }
}

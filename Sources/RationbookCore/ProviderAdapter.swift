// SPDX-License-Identifier: Apache-2.0

import Foundation

public protocol ProviderAdapter: Sendable {
    var providerID: String { get }
    var capabilities: AdapterCapabilities { get }
    func fetch(now: Date) throws -> ProviderStatus
    func detect() -> ProviderStatus
}

public enum ProviderErrorMapper {
    public static func structured(_ error: Error) -> (ProviderState, StructuredError) {
        switch error {
        case ProcessRunnerError.executableNotFound:
            return (.missing, StructuredError(code: "provider_missing", message: "The provider CLI was not found in a trusted executable location."))
        case ProcessRunnerError.unsafeExecutable:
            return (.unsupported, StructuredError(code: "unsafe_executable", message: "A provider executable was found only in an unsafe location."))
        case ProcessRunnerError.timedOut:
            return (.unavailable, StructuredError(code: "provider_timeout", message: "The provider did not respond before the refresh deadline."))
        case ProcessRunnerError.invalidOutput:
            return (.unsupported, StructuredError(code: "invalid_provider_output", message: "The provider returned an unsupported or malformed response."))
        case ProcessRunnerError.failed(_, _, let detail):
            let normalized = detail.lowercased()
            if ["login", "logged out", "unauthorized", "authentication", "sign in"].contains(where: normalized.contains) {
                return (.loggedOut, StructuredError(code: "provider_logged_out", message: "The provider CLI requires authentication."))
            }
            return (.unavailable, StructuredError(code: "provider_process_failed", message: "The provider CLI could not complete the quota request."))
        default:
            return (.unavailable, StructuredError(code: "provider_error", message: "The provider quota request failed."))
        }
    }

    public static func status(
        provider: String,
        agentLabel: String,
        capabilities: AdapterCapabilities,
        source: SourceMetadata,
        error: Error
    ) -> ProviderStatus {
        let (state, structuredError) = structured(error)
        return ProviderStatus(
            provider: provider,
            agentLabel: agentLabel,
            state: state,
            capabilities: capabilities,
            source: source,
            errors: [structuredError]
        )
    }
}

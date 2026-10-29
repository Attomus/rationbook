// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum OverallState: String, Codable, Sendable {
    case available, partial, unavailable
}

public enum ProviderState: String, Codable, Sendable {
    case available, partial, stale, unavailable, missing, loggedOut = "logged_out"
    case unsupported, waitingForObservation = "waiting_for_observation"
}

public enum Freshness: String, Codable, Sendable {
    case fresh, aging, stale, unknown
}

public enum DataQuality: String, Codable, Sendable {
    case authoritative
    case localObserved = "local_observed"
    case inferred
}

public enum PolicyState: String, Codable, Sendable {
    case available, exhausted, uncertain, unavailable
}

public enum EstimateConfidence: String, Codable, Sendable {
    case high, medium, low, unavailable
}

public struct AdapterCapabilities: Codable, Equatable, Sendable {
    public var supportsOnDemandRefresh: Bool
    public var supportsPushUpdates: Bool
    public var supportsAccountScope: Bool
    public var supportsModelScope: Bool

    public init(
        supportsOnDemandRefresh: Bool,
        supportsPushUpdates: Bool,
        supportsAccountScope: Bool = true,
        supportsModelScope: Bool = false
    ) {
        self.supportsOnDemandRefresh = supportsOnDemandRefresh
        self.supportsPushUpdates = supportsPushUpdates
        self.supportsAccountScope = supportsAccountScope
        self.supportsModelScope = supportsModelScope
    }
}

public struct SourceMetadata: Codable, Equatable, Sendable {
    public var name: String
    public var documentation: String
    public var maturity: String
    public var authentication: String
    public var testedToolVersion: String?

    public init(
        name: String,
        documentation: String,
        maturity: String,
        authentication: String = "inherited",
        testedToolVersion: String? = nil
    ) {
        self.name = name
        self.documentation = documentation
        self.maturity = maturity
        self.authentication = authentication
        self.testedToolVersion = testedToolVersion
    }
}

public struct ProviderAccount: Codable, Equatable, Sendable {
    public var plan: String?

    public init(plan: String? = nil) {
        self.plan = plan
    }
}

public struct StructuredError: Codable, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct WindowPolicy: Codable, Equatable, Sendable {
    public var reservePercent: Double
    public var safeRemainingPercent: Double
    public var state: PolicyState
}

public struct ObservedRate: Codable, Equatable, Sendable {
    public var netChangePPPerWallHour: Double
    public var forecastBurnPPPerWallHour: Double
    public var confidence: EstimateConfidence
    public var sampleCount: Int
    public var intervalStartedAt: Date
}

public struct ReserveScenario: Codable, Equatable, Sendable {
    public var hoursUntilReserve: Double
    public var hoursUntilExpectedReset: Double?
    public var firstEvent: String
    public var confidence: EstimateConfidence
}

public struct QuotaWindow: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var providerID: String?
    public var providerLabel: String?
    public var displayLabel: String
    public var scope: String
    public var model: String?
    public var durationSeconds: Int?
    public var observedAt: Date
    public var freshness: Freshness
    /// Persists missing-window evidence independently of age until the source reports it again.
    public var invalidationReason: String?
    public var usedPercent: Double
    public var remainingPercent: Double
    public var expectedResetsAt: Date?
    public var resetObservedAt: Date?
    public var dataQuality: DataQuality
    public var policy: WindowPolicy?
    public var observedRate: ObservedRate?
    public var reserveScenario: ReserveScenario?
    public var forecastUnavailableReason: String?

    // Foundation converts provider_id to providerId before matching CodingKeys.
    private enum CodingKeys: String, CodingKey {
        case id, providerLabel, displayLabel, scope, model, durationSeconds, observedAt, freshness, invalidationReason
        case usedPercent, remainingPercent, expectedResetsAt, resetObservedAt, dataQuality
        case policy, observedRate, reserveScenario, forecastUnavailableReason
        case providerID = "providerId"
    }

    public init(
        id: String,
        providerID: String? = nil,
        providerLabel: String? = nil,
        displayLabel: String,
        scope: String = "account",
        model: String? = nil,
        durationSeconds: Int? = nil,
        observedAt: Date,
        freshness: Freshness = .unknown,
        usedPercent: Double,
        remainingPercent: Double? = nil,
        expectedResetsAt: Date? = nil,
        resetObservedAt: Date? = nil,
        dataQuality: DataQuality
    ) {
        self.id = id
        self.providerID = providerID
        self.providerLabel = providerLabel
        self.displayLabel = displayLabel
        self.scope = scope
        self.model = model
        self.durationSeconds = durationSeconds
        self.observedAt = observedAt
        self.freshness = freshness
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent ?? (100 - usedPercent)
        self.expectedResetsAt = expectedResetsAt
        self.resetObservedAt = resetObservedAt
        self.dataQuality = dataQuality
        self.forecastUnavailableReason = nil
    }
}

public struct ProviderStatus: Codable, Equatable, Identifiable, Sendable {
    public var id: String { provider }
    public var provider: String
    public var agentLabel: String
    public var state: ProviderState
    public var account: ProviderAccount?
    public var capabilities: AdapterCapabilities
    public var source: SourceMetadata
    public var windows: [QuotaWindow]
    public var errors: [StructuredError]
    public var planningState: PolicyState?
    public var limitingWindowID: String?
    public var modelSpecificCapacity: String?

    private enum CodingKeys: String, CodingKey {
        case provider, agentLabel, state, account, capabilities, source, windows, errors, planningState, modelSpecificCapacity
        case limitingWindowID = "limitingWindowId"
    }

    public init(
        provider: String,
        agentLabel: String,
        state: ProviderState,
        account: ProviderAccount? = nil,
        capabilities: AdapterCapabilities,
        source: SourceMetadata,
        windows: [QuotaWindow] = [],
        errors: [StructuredError] = [],
        planningState: PolicyState? = nil,
        limitingWindowID: String? = nil,
        modelSpecificCapacity: String? = nil
    ) {
        self.provider = provider
        self.agentLabel = agentLabel
        self.state = state
        self.account = account
        self.capabilities = capabilities
        self.source = source
        self.windows = windows
        self.errors = errors
        self.planningState = planningState
        self.limitingWindowID = limitingWindowID
        self.modelSpecificCapacity = modelSpecificCapacity
    }
}

public struct StatusEnvelope: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var generatedAt: Date
    public var overallState: OverallState
    public var providers: [ProviderStatus]
    public var errors: [StructuredError]

    public init(schemaVersion: Int = 1, generatedAt: Date = Date(), providers: [ProviderStatus], errors: [StructuredError] = []) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.providers = providers
        self.errors = errors
        let usable = providers.filter { [.available, .partial, .stale].contains($0.state) }.count
        if !providers.isEmpty, usable == providers.count, providers.allSatisfy({ $0.state == .available }) {
            self.overallState = .available
        } else if usable > 0 {
            self.overallState = .partial
        } else {
            self.overallState = .unavailable
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, overallState, providers, errors
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        overallState = try container.decode(OverallState.self, forKey: .overallState)
        providers = try container.decode([ProviderStatus].self, forKey: .providers)
        errors = try container.decodeIfPresent([StructuredError].self, forKey: .errors) ?? []
    }
}

public struct ForecastWindow: Codable, Equatable, Sendable {
    public var provider: String
    public var windowID: String
    public var displayLabel: String
    public var freshness: Freshness
    public var scenario: ReserveScenario?
    public var unavailableReason: String?

    private enum CodingKeys: String, CodingKey {
        case provider, displayLabel, freshness, scenario, unavailableReason
        case windowID = "windowId"
    }

}

public struct ForecastEnvelope: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var generatedAt: Date
    public var windows: [ForecastWindow]
}

public struct WindowSample: Codable, Equatable, Sendable {
    public var provider: String
    public var windowID: String
    public var usedPercent: Double
    public var remainingPercent: Double
    public var expectedResetsAt: Date?
    public var firstObservedAt: Date
    public var lastObservedAt: Date
    public var sampleCount: Int
    public var freshness: Freshness

    private enum CodingKeys: String, CodingKey {
        case provider, usedPercent, remainingPercent, expectedResetsAt, firstObservedAt, lastObservedAt, sampleCount, freshness
        case windowID = "windowId"
    }

}

public struct HistoryEnvelope: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var generatedAt: Date
    public var samples: [WindowSample]

    public init(schemaVersion: Int = 1, generatedAt: Date = Date(), samples: [WindowSample]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.samples = samples
    }
}

public enum MenuBarSummary {
    public static func title(providers: [ProviderStatus]) -> String {
        guard !providers.isEmpty else { return "Rationbook" }
        return providers.map { provider in
            let initial = String(provider.agentLabel.prefix(1)).uppercased()
            let remaining = HumanPresentation.visibleWindows(for: provider).filter { $0.scope == "account" }.map(\.remainingPercent).min()
            let value = remaining.map { String(format: "%.0f%%", $0) } ?? "—"
            let degraded = provider.state == .stale || provider.state == .partial ? "~" : ""
            return "\(initial) \(value)\(degraded)"
        }.joined(separator: " · ")
    }
}

public enum HumanPresentation {
    public static func historicalWindows(for provider: ProviderStatus, now: Date = Date()) -> [QuotaWindow] {
        let visibleIDs = Set(visibleWindows(for: provider).map(\.id))
        return provider.windows.filter {
            !visibleIDs.contains($0.id) || ($0.scope == "model"
                && [.stale, .unknown].contains($0.freshness)
                && ($0.expectedResetsAt.map { $0 < now } ?? false))
        }
    }

    public static func currentWindows(for provider: ProviderStatus, now: Date = Date()) -> [QuotaWindow] {
        let historicalIDs = Set(historicalWindows(for: provider, now: now).map(\.id))
        return visibleWindows(for: provider).filter { !historicalIDs.contains($0.id) }
    }

    public static func overallState(for providers: [ProviderStatus]) -> ProviderState {
        let states = providers.map { currentState(for: $0) }
        if states.isEmpty { return .unavailable }
        if states.allSatisfy({ $0 == .available }) { return .available }
        if states.allSatisfy({ $0 == .stale }) { return .stale }
        return states.contains { [.available, .partial, .stale].contains($0) } ? .partial : .unavailable
    }

    public static func currentState(for provider: ProviderStatus) -> ProviderState {
        if provider.errors.contains(where: { $0.code == "provider_logged_out" }) { return .loggedOut }
        if provider.errors.contains(where: { $0.code == "waiting_for_observation" }) { return .waitingForObservation }
        let windows = currentWindows(for: provider)
        guard !windows.isEmpty, [.available, .partial, .stale].contains(provider.state) else {
            return provider.state
        }
        let freshCount = windows.filter { [.fresh, .aging].contains($0.freshness) }.count
        if freshCount == 0 { return .stale }
        if freshCount < windows.count { return .partial }
        // Only historical-window diagnostics may be omitted from the current summary.
        let historical = historicalWindows(for: provider)
        let hasCurrentError = provider.errors.contains {
            $0.code != "quota_window_absent_after_reset" || historical.isEmpty
        }
        return hasCurrentError ? .partial : .available
    }

    public static func visibleWindows(for provider: ProviderStatus) -> [QuotaWindow] {
        guard provider.provider == "openai" else { return provider.windows }
        return provider.windows.filter { window in
            let providerID = window.providerID?.lowercased()
            let label = (window.providerLabel ?? window.displayLabel).lowercased()
            return providerID != "codex_bengalfox" && !label.contains("codex-spark")
        }
    }
}

public struct WindowDisplayPreferences: Equatable, Sendable {
    public var hiddenWindowKeys: Set<String>

    public init(hiddenWindowKeys: Set<String> = []) {
        self.hiddenWindowKeys = hiddenWindowKeys
    }

    public static func key(providerID: String, windowID: String) -> String {
        "\(providerID)::\(windowID)"
    }

    public func isVisible(providerID: String, windowID: String) -> Bool {
        !hiddenWindowKeys.contains(Self.key(providerID: providerID, windowID: windowID))
    }

    public func visibleWindows(for provider: ProviderStatus) -> [QuotaWindow] {
        HumanPresentation.visibleWindows(for: provider).filter {
            isVisible(providerID: provider.provider, windowID: $0.id)
        }
    }

    public mutating func setVisible(_ visible: Bool, providerID: String, windowID: String) {
        let key = Self.key(providerID: providerID, windowID: windowID)
        if visible {
            hiddenWindowKeys.remove(key)
        } else {
            hiddenWindowKeys.insert(key)
        }
    }
}

public enum RationbookJSON {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

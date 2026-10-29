// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A quota-only observation supplied by an explicitly linked composition.
///
/// The boundary deliberately has no credential, endpoint, raw-response, command,
/// or persistence fields. Text values describe quota semantics; linked sources
/// must canonicalize them and must not place account identity in those fields.
/// Rationbook validates and normalizes the returned values before policy or storage.
public struct CapacitySourceSnapshot: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        public var id: String
        public var providerID: String
        public var providerLabel: String?
        public var displayLabel: String
        public var scope: String
        public var model: String?
        public var durationSeconds: Int
        public var usedPercent: Double
        public var resetsAt: Date?

        public init(
            id: String,
            providerID: String,
            providerLabel: String? = nil,
            displayLabel: String,
            scope: String,
            model: String? = nil,
            durationSeconds: Int,
            usedPercent: Double,
            resetsAt: Date? = nil
        ) {
            self.id = id
            self.providerID = providerID
            self.providerLabel = providerLabel
            self.displayLabel = displayLabel
            self.scope = scope
            self.model = model
            self.durationSeconds = durationSeconds
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
        }
    }

    public var provider: String
    public var agentLabel: String
    public var observedAt: Date
    public var provenance: SourceMetadata
    public var windows: [Window]

    public init(
        provider: String,
        agentLabel: String,
        observedAt: Date,
        provenance: SourceMetadata,
        windows: [Window]
    ) {
        self.provider = provider
        self.agentLabel = agentLabel
        self.observedAt = observedAt
        self.provenance = provenance
        self.windows = windows
    }
}

public protocol CapacitySource: Sendable {
    var sourceID: String { get }
    func refresh(now: Date) throws -> CapacitySourceSnapshot
}

public enum CapacitySourceError: Error, LocalizedError, Equatable {
    case invalidSnapshot

    public var errorDescription: String? {
        "The explicitly linked capacity source returned an invalid quota-only observation."
    }
}

public struct CapacitySourceAdapter: ProviderAdapter {
    public let source: any CapacitySource
    public let providerID: String
    public let capabilities = AdapterCapabilities(
        supportsOnDemandRefresh: true,
        supportsPushUpdates: false,
        supportsAccountScope: true,
        supportsModelScope: true
    )

    public init(source: any CapacitySource, providerID: String = "anthropic") {
        self.source = source
        self.providerID = providerID
    }

    public func fetch(now: Date) throws -> ProviderStatus {
        try Self.normalize(source.refresh(now: now), expectedProvider: providerID, now: now)
    }

    public func detect() -> ProviderStatus {
        ProviderStatus(
            provider: providerID,
            agentLabel: "Anthropic",
            state: .waitingForObservation,
            capabilities: capabilities,
            source: SourceMetadata(
                name: source.sourceID,
                documentation: "external",
                maturity: "unknown",
                authentication: "external"
            ),
            errors: [
                StructuredError(
                    code: "capacity_source_waiting",
                    message: "The explicitly linked capacity source has not produced an observation."
                ),
            ]
        )
    }

    public static func normalize(
        _ snapshot: CapacitySourceSnapshot,
        expectedProvider: String,
        now: Date
    ) throws -> ProviderStatus {
        guard snapshot.provider == expectedProvider,
              snapshot.provider == "anthropic",
              validText(snapshot.agentLabel, maximum: 80),
              validText(snapshot.provenance.name, maximum: 80),
              validText(snapshot.provenance.documentation, maximum: 80),
              validText(snapshot.provenance.maturity, maximum: 80),
              validText(snapshot.provenance.authentication, maximum: 80),
              snapshot.observedAt <= now.addingTimeInterval(300),
              !snapshot.windows.isEmpty,
              snapshot.windows.count <= 8 else {
            throw CapacitySourceError.invalidSnapshot
        }

        var identifiers = Set<String>()
        let windows = try snapshot.windows.map { window -> QuotaWindow in
            guard validText(window.id, maximum: 160),
                  identifiers.insert(window.id).inserted,
                  validText(window.providerID, maximum: 80),
                  validText(window.displayLabel, maximum: 80),
                  ["account", "model"].contains(window.scope),
                  window.scope == "model" ? validOptionalText(window.model, maximum: 80) : window.model == nil,
                  validNullableText(window.providerLabel, maximum: 80),
                  (60...2_678_400).contains(window.durationSeconds),
                  window.usedPercent.isFinite,
                  (0...100).contains(window.usedPercent) else {
                throw CapacitySourceError.invalidSnapshot
            }
            return QuotaWindow(
                id: window.id,
                providerID: window.providerID,
                providerLabel: window.providerLabel,
                displayLabel: window.displayLabel,
                scope: window.scope,
                model: window.model,
                durationSeconds: window.durationSeconds,
                observedAt: snapshot.observedAt,
                freshness: FreshnessPolicy.classify(
                    provider: snapshot.provider,
                    observedAt: snapshot.observedAt,
                    now: now
                ),
                usedPercent: window.usedPercent,
                expectedResetsAt: window.resetsAt,
                dataQuality: .localObserved
            )
        }
        let modelFreshness = windows.filter { $0.scope == "model" }.map(\.freshness)
        let modelSpecificCapacity: String
        if modelFreshness.contains(where: { [.fresh, .aging].contains($0) }) {
            modelSpecificCapacity = "observed"
        } else if !modelFreshness.isEmpty {
            modelSpecificCapacity = "stale"
        } else {
            modelSpecificCapacity = "unknown"
        }
        let hasCurrent = windows.contains { [.fresh, .aging].contains($0.freshness) }
        return ProviderStatus(
            provider: snapshot.provider,
            agentLabel: snapshot.agentLabel,
            state: hasCurrent ? .available : .stale,
            capabilities: AdapterCapabilities(
                supportsOnDemandRefresh: true,
                supportsPushUpdates: false,
                supportsAccountScope: windows.contains { $0.scope == "account" },
                supportsModelScope: windows.contains { $0.scope == "model" }
            ),
            source: snapshot.provenance,
            windows: windows,
            modelSpecificCapacity: modelSpecificCapacity
        )
    }

    private static func validText(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximum
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func validOptionalText(_ value: String?, maximum: Int) -> Bool {
        guard let value else { return false }
        return validText(value, maximum: maximum)
    }

    private static func validNullableText(_ value: String?, maximum: Int) -> Bool {
        value.map { validText($0, maximum: maximum) } ?? true
    }
}

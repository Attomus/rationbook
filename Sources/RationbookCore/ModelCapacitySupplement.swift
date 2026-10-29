// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct ModelCapacitySupplement: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public var model: String
        public var displayLabel: String
        public var durationSeconds: Int
        public var usedPercent: Double
        public var resetsAt: Date?

        public init(
            model: String,
            displayLabel: String,
            durationSeconds: Int,
            usedPercent: Double,
            resetsAt: Date? = nil
        ) {
            self.model = model
            self.displayLabel = displayLabel
            self.durationSeconds = durationSeconds
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
        }
    }

    public var schemaVersion: Int
    public var provider: String
    public var observedAt: Date
    public var windows: [Window]

    public init(
        schemaVersion: Int = 1,
        provider: String = "anthropic",
        observedAt: Date,
        windows: [Window]
    ) {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.observedAt = observedAt
        self.windows = windows
    }
}

public enum ModelCapacitySupplementError: Error, LocalizedError, Equatable {
    case tooLarge
    case invalidJSON
    case unsupportedSchema
    case unsupportedProvider
    case invalidWindow
    case duplicateWindow

    public var errorDescription: String? {
        switch self {
        case .tooLarge: return "The local model-capacity supplement exceeds 64 KiB."
        case .invalidJSON: return "The local model-capacity supplement has an invalid or unsupported JSON shape."
        case .unsupportedSchema: return "The local model-capacity supplement uses an unsupported schema version."
        case .unsupportedProvider: return "The local model-capacity supplement names an unsupported provider."
        case .invalidWindow: return "The local model-capacity supplement contains an invalid quota window."
        case .duplicateWindow: return "The local model-capacity supplement contains duplicate model windows."
        }
    }
}

public struct ModelCapacitySupplementManager: Sendable {
    public static let maximumBytes = 64 * 1_024
    public var paths: RationbookPaths

    public init(paths: RationbookPaths = RationbookPaths()) {
        self.paths = paths
    }

    @discardableResult
    public func importData(_ data: Data, now: Date = Date()) throws -> ModelCapacitySupplement {
        let supplement = try Self.decodeAndValidate(data, now: now)
        try paths.atomicWrite(
            try RationbookJSON.encoder(pretty: true).encode(supplement),
            to: paths.modelCapacitySupplement
        )
        return supplement
    }

    public func load(now: Date = Date()) throws -> ModelCapacitySupplement? {
        guard FileManager.default.fileExists(atPath: paths.modelCapacitySupplement.path) else { return nil }
        try paths.validateFileForRead(paths.modelCapacitySupplement)
        let data = try Data(contentsOf: paths.modelCapacitySupplement, options: [.mappedIfSafe])
        return try Self.decodeAndValidate(data, now: now)
    }

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: paths.modelCapacitySupplement.path) else { return }
        try paths.removeOwnedFile(paths.modelCapacitySupplement)
    }

    public static func decodeAndValidate(_ data: Data, now: Date = Date()) throws -> ModelCapacitySupplement {
        guard data.count <= maximumBytes else { throw ModelCapacitySupplementError.tooLarge }
        try validateShape(data)
        let supplement: ModelCapacitySupplement
        do {
            supplement = try RationbookJSON.decoder().decode(ModelCapacitySupplement.self, from: data)
        } catch {
            throw ModelCapacitySupplementError.invalidJSON
        }
        guard supplement.schemaVersion == 1 else { throw ModelCapacitySupplementError.unsupportedSchema }
        guard supplement.provider == "anthropic" else { throw ModelCapacitySupplementError.unsupportedProvider }
        guard !supplement.windows.isEmpty, supplement.windows.count <= 8,
              supplement.observedAt <= now.addingTimeInterval(300),
              supplement.observedAt >= now.addingTimeInterval(-366 * 86_400) else {
            throw ModelCapacitySupplementError.invalidWindow
        }

        var identifiers = Set<String>()
        for window in supplement.windows {
            guard validText(window.model), validText(window.displayLabel),
                  !stableComponent(window.model).isEmpty,
                  window.durationSeconds >= 60, window.durationSeconds <= 366 * 86_400,
                  window.usedPercent.isFinite, (0...100).contains(window.usedPercent) else {
                throw ModelCapacitySupplementError.invalidWindow
            }
            if let resetsAt = window.resetsAt,
               resetsAt < supplement.observedAt.addingTimeInterval(-366 * 86_400)
                || resetsAt > supplement.observedAt.addingTimeInterval(366 * 86_400) {
                throw ModelCapacitySupplementError.invalidWindow
            }
            let identifier = stableIdentifier(for: window)
            guard identifiers.insert(identifier).inserted else {
                throw ModelCapacitySupplementError.duplicateWindow
            }
        }
        return supplement
    }

    public static func quotaWindows(
        from supplement: ModelCapacitySupplement,
        now: Date = Date()
    ) -> [QuotaWindow] {
        supplement.windows.map { window in
            QuotaWindow(
                id: stableIdentifier(for: window),
                providerID: stableComponent(window.model),
                providerLabel: window.model,
                displayLabel: window.displayLabel,
                scope: "model",
                model: window.model,
                durationSeconds: window.durationSeconds,
                observedAt: supplement.observedAt,
                freshness: FreshnessPolicy.classify(
                    provider: supplement.provider,
                    observedAt: supplement.observedAt,
                    now: now
                ),
                usedPercent: window.usedPercent,
                expectedResetsAt: window.resetsAt,
                dataQuality: .localObserved
            )
        }
    }

    private static func validateShape(_ data: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys).isSubset(of: ["schema_version", "provider", "observed_at", "windows"]),
              let windows = root["windows"] as? [[String: Any]] else {
            throw ModelCapacitySupplementError.invalidJSON
        }
        let allowedWindowKeys = Set(["model", "display_label", "duration_seconds", "used_percent", "resets_at"])
        guard windows.allSatisfy({ Set($0.keys).isSubset(of: allowedWindowKeys) }) else {
            throw ModelCapacitySupplementError.invalidJSON
        }
    }

    private static func validText(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 80 && !trimmed.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func stableIdentifier(for window: ModelCapacitySupplement.Window) -> String {
        "anthropic:model:\(stableComponent(window.model)):\(window.durationSeconds)"
    }

    private static func stableComponent(_ value: String) -> String {
        var result = ""
        for character in value.lowercased() {
            let safe = character.isLetter || character.isNumber
            if safe {
                result.append(character)
            } else if result.last != "-" {
                result.append("-")
            }
            if result.count == 48 { break }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

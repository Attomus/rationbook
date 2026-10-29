// SPDX-License-Identifier: Apache-2.0

import AppKit
import Combine
import RationbookCore
import ServiceManagement
import SwiftUI
import UserNotifications

enum RationbookAppearance: String, CaseIterable, Identifiable {
    case automatic, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum RationbookDetailLevel: String {
    case essential, full
}

public struct RationbookUIConfiguration: @unchecked Sendable {
    public var appName: String
    public var subtitle: String
    public var defaultsPrefix: String
    public var showsPublicIntegrations: Bool
    public var fixedReserveSettings: ReserveSettings?
    public var privacySummary: String
    public var anthropicRefreshDescription: String
    public var refreshHelp: String
    let serviceFactory: @MainActor @Sendable () throws -> RationbookService
    let statusTransform: @Sendable (StatusEnvelope) -> StatusEnvelope

    public init(
        appName: String,
        subtitle: String,
        defaultsPrefix: String,
        showsPublicIntegrations: Bool,
        fixedReserveSettings: ReserveSettings? = nil,
        privacySummary: String,
        anthropicRefreshDescription: String,
        refreshHelp: String,
        serviceFactory: @escaping @MainActor @Sendable () throws -> RationbookService,
        statusTransform: @escaping @Sendable (StatusEnvelope) -> StatusEnvelope = { $0 }
    ) {
        self.appName = appName
        self.subtitle = subtitle
        self.defaultsPrefix = defaultsPrefix
        self.showsPublicIntegrations = showsPublicIntegrations
        self.fixedReserveSettings = fixedReserveSettings
        self.privacySummary = privacySummary
        self.anthropicRefreshDescription = anthropicRefreshDescription
        self.refreshHelp = refreshHelp
        self.serviceFactory = serviceFactory
        self.statusTransform = statusTransform
    }

    public static let publicRationbook = RationbookUIConfiguration(
        appName: "Rationbook",
        subtitle: "Local capacity",
        defaultsPrefix: "org.attomus.rationbook",
        showsPublicIntegrations: true,
        privacySummary: "No Rationbook account, telemetry, provider credentials, prompt storage, or cloud backend. The Claude helper processes a complete local status event transiently and stores only documented aggregate quota fields.",
        anthropicRefreshDescription: "local Claude observation checked",
        refreshHelp: "Refresh Codex and check the latest local Claude observation.",
        serviceFactory: { try RationbookService() }
    )
}

public struct RationbookMenuScene: Scene {
    @StateObject private var model: RationbookAppModel

    public init(configuration: RationbookUIConfiguration) {
        _model = StateObject(wrappedValue: RationbookAppModel(configuration: configuration))
    }

    public var body: some Scene {
        let _ = model
        Settings {
            RationbookSettingsView(model: model)
                .frame(width: 620, height: 690)
        }
    }
}

@MainActor
final class RationbookAppModel: ObservableObject {
    @Published var envelope = StatusEnvelope(providers: [])
    @Published var isRefreshing = false
    @Published var lastError: String?
    @Published var integrationMessage: String?
    @Published var waitingForClaude = false
    private var claudeRefreshBaseline: Date?
    private var interactiveClaudeRefresh = false
    private var claudeRefreshTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    @Published var reserveSettings = ReserveSettings()
    @Published var retentionDays = 60
    @Published var history: [WindowSample] = []
    @Published var notificationsEnabled = false
    @Published var appearance: RationbookAppearance
    @Published var claudeRefreshInterval: ClaudeRefreshInterval {
        didSet {
            UserDefaults.standard.set(claudeRefreshInterval.rawValue, forKey: "\(configuration.defaultsPrefix).claudeRefreshMinutes")
        }
    }
    @Published var claudeNeedsSignIn = false
    @Published var claudeFeedInstalled = false
    @Published var launchAtLoginEnabled = false
    @Published var launchAtLoginRequiresApproval = false
    @Published var refreshFeedback: String?
    @Published var windowDisplayPreferences = WindowDisplayPreferences()
    let configuration: RationbookUIConfiguration
    private var menuController: RationbookMenuController?
    private var service: RationbookService?
    private var backgroundTask: Task<Void, Never>?

    init(configuration: RationbookUIConfiguration) {
        self.configuration = configuration
        let refreshMinutes = UserDefaults.standard.object(forKey: "\(configuration.defaultsPrefix).claudeRefreshMinutes") as? Int
        claudeRefreshInterval = refreshMinutes.flatMap(ClaudeRefreshInterval.init(rawValue:)) ?? .fifteenMinutes
        windowDisplayPreferences = WindowDisplayPreferences(
            hiddenWindowKeys: Set(UserDefaults.standard.stringArray(
                forKey: "\(configuration.defaultsPrefix).hiddenWindowKeys"
            ) ?? [])
        )
        appearance = RationbookAppearance(
            rawValue: UserDefaults.standard.string(forKey: "\(configuration.defaultsPrefix).appearance") ?? ""
        ) ?? .automatic
        claudeFeedInstalled = FileManager.default.fileExists(atPath: RationbookPaths().claudeIntegration.path)
        refreshLaunchAtLoginState()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshClaudeAutomatically() }
        }
        Self.applyAppearance(appearance)
        do {
            service = try configuration.serviceFactory()
            if let fixed = configuration.fixedReserveSettings {
                try service?.updateReserveSettings(fixed)
            }
            reserveSettings = service?.reserveSettings ?? ReserveSettings()
            retentionDays = service?.retentionDays() ?? 60
            notificationsEnabled = service?.notificationsEnabled() ?? false
            refresh(force: false, showFeedback: false)
            backgroundTask = Task { [weak self] in
                var minute = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    guard let self, !Task.isCancelled else { return }
                    minute += 1
                    self.refreshClaudeAutomatically()
                    if minute.isMultiple(of: 5) || !self.envelope.providers.flatMap(\.windows).isEmpty {
                        self.refresh(force: minute.isMultiple(of: 5), showFeedback: false)
                    }
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
        menuController = RationbookMenuController(model: self)
    }

    func updateReserve(_ settings: ReserveSettings) {
        if let fixed = configuration.fixedReserveSettings {
            reserveSettings = fixed
            return
        }
        reserveSettings = settings
        do {
            try service?.updateReserveSettings(settings)
            refresh(force: false)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func updateRetention(_ days: Int) {
        retentionDays = days
        do {
            try service?.updateRetentionDays(days)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func updateNotifications(_ enabled: Bool) {
        notificationsEnabled = enabled
        do { try service?.updateNotificationsEnabled(enabled) }
        catch { lastError = error.localizedDescription; notificationsEnabled = !enabled; return }
        if enabled {
            Task {
                do {
                    let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                    if !granted {
                        notificationsEnabled = false
                        try? service?.updateNotificationsEnabled(false)
                        lastError = "Notifications were not authorized in System Settings."
                    }
                } catch {
                    lastError = error.localizedDescription
                }
            }
        }
    }

    func updateAppearance(_ value: RationbookAppearance) {
        appearance = value
        UserDefaults.standard.set(value.rawValue, forKey: "\(configuration.defaultsPrefix).appearance")
        Self.applyAppearance(value)
    }

    func isWindowVisible(providerID: String, windowID: String) -> Bool {
        windowDisplayPreferences.isVisible(providerID: providerID, windowID: windowID)
    }

    func updateWindowVisibility(providerID: String, windowID: String, visible: Bool) {
        windowDisplayPreferences.setVisible(visible, providerID: providerID, windowID: windowID)
        persistWindowDisplayPreferences()
    }

    func showAllWindows() {
        windowDisplayPreferences.hiddenWindowKeys.removeAll()
        persistWindowDisplayPreferences()
    }

    private func persistWindowDisplayPreferences() {
        UserDefaults.standard.set(
            windowDisplayPreferences.hiddenWindowKeys.sorted(),
            forKey: "\(configuration.defaultsPrefix).hiddenWindowKeys"
        )
    }

    func updateLaunchAtLogin(_ enabled: Bool) {
        lastError = nil
        integrationMessage = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLaunchAtLoginState()
            if launchAtLoginRequiresApproval {
                integrationMessage = "Open at Login needs approval in System Settings → General → Login Items."
            } else {
                integrationMessage = launchAtLoginEnabled
                    ? "\(configuration.appName) will open when you log in."
                    : "\(configuration.appName) will no longer open at login."
            }
        } catch {
            refreshLaunchAtLoginState()
            lastError = "Open at Login could not be updated: \(error.localizedDescription)"
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func copyDiagnostics() {
        lastError = nil
        integrationMessage = nil
        guard let service else { return }
        do {
            let info = Bundle.main.infoDictionary
            let report = RationbookDiagnostics.report(
                from: service.doctor(),
                appVersion: info?["CFBundleShortVersionString"] as? String ?? RationbookBuild.version,
                appBuild: info?["CFBundleVersion"] as? String ?? RationbookBuild.build
            )
            let text = String(decoding: try RationbookJSON.encoder(pretty: true).encode(report), as: UTF8.self)
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(text, forType: .string) else {
                throw CocoaError(.fileWriteUnknown)
            }
            integrationMessage = "Privacy-safe diagnostics copied. They contain no quota values, account identifiers, prompts, or credentials."
        } catch {
            lastError = "Diagnostics could not be copied: \(error.localizedDescription)"
        }
    }

    func refreshLaunchAtLoginState() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginEnabled = true
            launchAtLoginRequiresApproval = false
        case .requiresApproval:
            launchAtLoginEnabled = true
            launchAtLoginRequiresApproval = true
        case .notRegistered, .notFound:
            launchAtLoginEnabled = false
            launchAtLoginRequiresApproval = false
        @unknown default:
            launchAtLoginEnabled = false
            launchAtLoginRequiresApproval = false
        }
    }

    private static func applyAppearance(_ value: RationbookAppearance) {
        NSApplication.shared.appearance = switch value {
        case .automatic: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    func refresh(force: Bool = true, showFeedback: Bool = true) {
        guard let service, !isRefreshing else { return }
        isRefreshing = true
        if showFeedback { refreshFeedback = nil }
        let statusTransform = configuration.statusTransform
        Task {
            let previous = envelope
            let result = await Task.detached {
                let envelope = statusTransform(service.status(refresh: force))
                let history = envelope.providers.flatMap { provider in
                    provider.windows.flatMap { window in
                        (try? service.history(
                            provider: provider.provider,
                            windowID: window.id,
                            limit: 120
                        )) ?? []
                    }
                }
                return (envelope, history)
            }.value
            envelope = result.0
            history = result.1
            if waitingForClaude, interactiveClaudeRefresh,
               let observed = envelope.providers.first(where: { $0.provider == "anthropic" })?
                .windows.filter({ $0.scope == "account" }).map(\.observedAt).max(),
               observed > (claudeRefreshBaseline ?? .distantPast) {
                waitingForClaude = false
                claudeNeedsSignIn = false
                claudeRefreshTask?.cancel()
                integrationMessage = "Claude usage updated. You can close the Terminal window."
            }
            notifyForTransitions(from: previous, to: result.0)
            isRefreshing = false
            if showFeedback {
                let message = result.0.providers.map { provider in
                    let name = provider.provider == "openai" ? "Codex" : "Claude"
                    if !provider.errors.isEmpty || provider.windows.isEmpty {
                        return "\(name): no new reading"
                    }
                    if provider.provider == "openai", force {
                        return "Codex refreshed"
                    }
                    return "\(name): showing local observations"
                }.joined(separator: " · ")
                refreshFeedback = message
                Task {
                    try? await Task.sleep(for: .seconds(6))
                    if refreshFeedback == message { refreshFeedback = nil }
                }
            }
        }
    }

    func refreshOnOpen() {
        refreshClaudeAutomatically()
        let now = Date()
        let shouldForce = envelope.providers.isEmpty || envelope.providers.contains { provider in
            guard let newest = provider.windows.map(\.observedAt).max() else { return true }
            return now.timeIntervalSince(newest) > 30
        }
        refresh(force: waitingForClaude ? false : shouldForce, showFeedback: false)
    }

    func installCLI() {
        lastError = nil
        integrationMessage = nil
        do {
            guard let source = Bundle.main.resourceURL?.appendingPathComponent("bin/rationbook") else {
                throw CLIIntegrationError.sourceMissing
            }
            let record = try CLIIntegrationManager().install(source: source)
            integrationMessage = "CLI installed at \(record.symlinkPath)"
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshClaudeAutomatically(force: Bool = false) {
        guard configuration.showsPublicIntegrations, claudeFeedInstalled, !waitingForClaude else { return }
        let now = Date()
        let attemptKey = "\(configuration.defaultsPrefix).lastClaudeRefreshAttempt"
        let lastAttempt = UserDefaults.standard.object(forKey: attemptKey) as? Date
        let windows = envelope.providers.first(where: { $0.provider == "anthropic" })?
            .windows.filter { $0.scope == "account" } ?? []
        if !force {
            guard claudeRefreshInterval.isDue(lastAttempt: lastAttempt, observations: windows.map(\.observedAt), now: now) else { return }
        }
        UserDefaults.standard.set(now, forKey: attemptKey)
        claudeRefreshBaseline = now
        interactiveClaudeRefresh = false
        waitingForClaude = true
        lastError = nil
        integrationMessage = "Refreshing Claude usage… Last-known readings remain visible."
        claudeRefreshTask = Task { [weak self] in
            do {
                let needsSignIn = await Task.detached {
                    ClaudeIntegrationManager().requiresSignIn()
                }.value
                try Task.checkCancellation()
                if needsSignIn { throw ClaudeIntegrationError.signInRequired }
                try await ClaudeIntegrationManager().refreshUsageAutomatically(
                    helperSource: Bundle.main.resourceURL?.appendingPathComponent("bin/rationbook-claude-helper")
                )
                guard let self else { return }
                self.waitingForClaude = false
                self.claudeNeedsSignIn = false
                self.integrationMessage = "Claude usage updated."
                self.refresh(force: false, showFeedback: false)
            } catch is CancellationError {
                self?.waitingForClaude = false
            } catch {
                self?.waitingForClaude = false
                self?.claudeNeedsSignIn = (error as? ClaudeIntegrationError) == .signInRequired
                self?.integrationMessage = "Claude refresh failed: \(error.localizedDescription) Last-known readings are preserved."
            }
        }
    }

    func refreshClaude() { openClaudeTerminal(signIn: false) }

    func signInToClaude() { openClaudeTerminal(signIn: true) }

    private func openClaudeTerminal(signIn: Bool) {
        guard !waitingForClaude else { return }
        lastError = nil
        do {
            let command = try ClaudeIntegrationManager().prepareUsageCommand(
                helperSource: Bundle.main.resourceURL?.appendingPathComponent("bin/rationbook-claude-helper"), signIn: signIn
            )
            claudeRefreshBaseline = Date()
            guard NSWorkspace.shared.open(command) else {
                throw ProcessRunnerError.invalidOutput("Could not open Terminal for Claude usage.")
            }
            interactiveClaudeRefresh = true
            waitingForClaude = true
            integrationMessage = signIn
                ? "Complete Claude sign-in in Terminal, then enter /usage and press Esc after the percentages appear. Rationbook will confirm the update here."
                : "In Terminal, check that /usage shows subscription percentages, then press Esc. Rationbook will confirm the update here; you can then close Claude with /exit."
            claudeRefreshTask?.cancel()
            claudeRefreshTask = Task { [weak self] in
                for _ in 0..<60 {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self, self.waitingForClaude else { return }
                    self.refresh(force: false, showFeedback: false)
                }
                guard let self, self.waitingForClaude else { return }
                let needsSignIn = await Task.detached {
                    ClaudeIntegrationManager().requiresSignIn()
                }.value
                let message = ClaudeIntegrationManager.refreshFailureMessage(needsSignIn: needsSignIn)
                guard !Task.isCancelled, self.waitingForClaude else { return }
                self.waitingForClaude = false
                self.claudeNeedsSignIn = needsSignIn
                self.integrationMessage = message
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func installClaudeFeed() {
        lastError = nil
        integrationMessage = nil
        do {
            guard let source = Bundle.main.resourceURL?.appendingPathComponent("bin/rationbook-claude-helper") else {
                throw ClaudeIntegrationError.helperMissing
            }
            _ = try ClaudeIntegrationManager().install(helperSource: source)
            claudeFeedInstalled = true
            integrationMessage = "Claude feed enabled. Usage refreshes in the background, on open and on wake. Choose Refresh Claude to check now, or Open Claude in Terminal if sign-in is needed."
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func uninstallClaudeFeed() {
        lastError = nil
        integrationMessage = nil
        do {
            try ClaudeIntegrationManager().uninstall()
            claudeFeedInstalled = false
            integrationMessage = "Claude Code quota feed removed and the previous status line restored."
            refresh(force: false, showFeedback: false)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func notifyForTransitions(from previous: StatusEnvelope, to current: StatusEnvelope) {
        guard notificationsEnabled, !previous.providers.isEmpty else { return }
        for provider in current.providers {
            guard let oldProvider = previous.providers.first(where: { $0.provider == provider.provider }) else { continue }
            for window in provider.windows where window.scope == "account" {
                guard let old = oldProvider.windows.first(where: { $0.id == window.id }) else { continue }
                let title: String?
                let body: String
                if old.policy?.state != .exhausted, window.policy?.state == .exhausted {
                    title = "\(configuration.appName) reserve reached"
                    body = "\(provider.agentLabel) / \(window.displayLabel) has \(String(format: "%.0f", window.remainingPercent))% remaining."
                } else if old.resetObservedAt != window.resetObservedAt, window.resetObservedAt != nil {
                    title = "\(configuration.appName) reset observed"
                    body = "\(provider.agentLabel) / \(window.displayLabel) rolled into a new quota window."
                } else if crossedProlongedStaleThreshold(provider: provider.provider, old: old, current: window, previousAt: previous.generatedAt, currentAt: current.generatedAt) {
                    title = "\(configuration.appName) data is stale"
                    body = "\(provider.agentLabel) / \(window.displayLabel) has remained stale beyond twice its stale threshold."
                } else {
                    title = nil
                    body = ""
                }
                guard let title else { continue }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                let request = UNNotificationRequest(identifier: "rationbook.\(provider.provider).\(window.id).\(title)", content: content, trigger: nil)
                UNUserNotificationCenter.current().add(request)
            }
        }
    }

    private func crossedProlongedStaleThreshold(
        provider: String,
        old: QuotaWindow,
        current: QuotaWindow,
        previousAt: Date,
        currentAt: Date
    ) -> Bool {
        let threshold: TimeInterval = provider == "openai" ? 1_800 : 7_200
        return currentAt.timeIntervalSince(current.observedAt) > threshold
            && previousAt.timeIntervalSince(old.observedAt) <= threshold
    }
}

@MainActor
private final class RationbookMenuController: NSObject {
    private let model: RationbookAppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var changes: AnyCancellable?

    init(model: RationbookAppModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.animates = false
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        updateImage()
        changes = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateImage() }
        }
    }

    private func updateImage() {
        item.button?.image = MenuBarGaugeRenderer.image(
            providers: model.envelope.providers,
            displayPreferences: model.windowDisplayPreferences,
            appName: model.configuration.appName
        )
        item.button?.setAccessibilityLabel(MenuBarGaugeRenderer.accessibilityLabel(
            providers: model.envelope.providers,
            displayPreferences: model.windowDisplayPreferences,
            appName: model.configuration.appName
        ))
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item.button else { return }
        let height = max(300, (button.window?.screen?.visibleFrame.height ?? 720) - 40)
        let content = RationbookPopover(model: model, maximumHeight: height) { [weak self] requestedHeight in
            guard let self, let button = self.item.button else { return }
            self.popover.contentSize = NSSize(width: 520, height: requestedHeight)
            if self.popover.isShown {
                self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
        .frame(width: 520)
        popover.contentViewController = NSHostingController(rootView: content)
        popover.contentSize = NSSize(width: 520, height: height)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

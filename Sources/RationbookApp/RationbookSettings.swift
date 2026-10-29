// SPDX-License-Identifier: Apache-2.0

import AppKit
import RationbookCore
import SwiftUI

struct RationbookSettingsView: View {
    @ObservedObject var model: RationbookAppModel
    @State private var confirmClaudeFeedInstall = false
    @State private var confirmClaudeFeedUninstall = false
    @State private var privacyExpanded = false
    @State private var windowVisibilityExpanded = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                settingsHeader
                feedbackBanner
                settingsSurface
            }
            .padding(18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.refreshLaunchAtLoginState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLaunchAtLoginState()
        }
        .confirmationDialog("Enable the local Claude Code quota feed?", isPresented: $confirmClaudeFeedInstall, titleVisibility: .visible) {
            Button("Enable feed") { model.installClaudeFeed() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rationbook will add a status-line command to Claude Code settings, retain the prior status-line object for restoration, and process each complete status event transiently. Only documented aggregate quota fields are stored. Rationbook will also refresh usage through Claude Code in the background while the app is running, and when you open the panel or wake your Mac; sign-in stays in Claude Code.")
        }
        .confirmationDialog("Remove the Claude Code quota feed?", isPresented: $confirmClaudeFeedUninstall, titleVisibility: .visible) {
            Button("Remove feed", role: .destructive) { model.uninstallClaudeFeed() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rationbook will restore the prior status-line object only if the installed entry is still unchanged, then remove its helper and ownership record.")
        }
    }

    private var settingsHeader: some View {
        HStack(spacing: 12) {
            RationbookSymbol(showsTile: true)
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings")
                    .font(.title3.weight(.semibold))
                Text("Capacity preferences and local integrations")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ProviderStatePill(state: overallProviderState, compact: true)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var feedbackBanner: some View {
        if let error = model.lastError {
            IntegrationFeedbackBanner(
                message: error,
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange
            )
        } else if let message = model.integrationMessage {
            IntegrationFeedbackBanner(
                message: message,
                systemImage: "checkmark.circle.fill",
                tint: .green
            )
        }
    }

    private var settingsSurface: some View {
        VStack(spacing: 0) {
            if model.configuration.showsPublicIntegrations {
                settingsIntegrations
                    .padding(14)
                Divider()
            }
            reserveThresholds
                .padding(14)
            Divider()
            windowVisibilitySection
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            alertsRow
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            Divider()
            launchAtLoginRow
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            appearanceRow
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            historyRow
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            DisclosureGroup(isExpanded: $privacyExpanded) {
                Text(model.configuration.privacySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            } label: {
                Label("Privacy and local data handling", systemImage: "lock.shield")
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            supportRow
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        }
    }

    private var settingsIntegrations: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeading(title: "Integrations", detail: "Quota history stays on this Mac; provider credentials stay with their tools.")
            IntegrationRow(
                provider: "openai",
                title: "Codex CLI",
                detail: "Reads quota data from your local Codex session.",
                state: providerState("openai")
            )
            Divider()
            HStack(spacing: 10) {
                SettingsRowIcon(systemImage: "terminal")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rationbook CLI")
                        .font(.caption.weight(.medium))
                    Text("Use capacity data in your terminal and automation.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Install Rationbook CLI", action: model.installCLI)
                    .controlSize(.small)
            }
            Divider()
            IntegrationRow(
                provider: "anthropic",
                title: "Claude Code quota feed",
                detail: anthropicIntegrationDetail,
                state: providerState("anthropic"),
                actionTitle: anthropicActionTitle,
                action: {
                    if model.claudeFeedInstalled { confirmClaudeFeedUninstall = true }
                    else { confirmClaudeFeedInstall = true }
                }
            )
            Picker("Claude refresh", selection: $model.claudeRefreshInterval) {
                ForEach(ClaudeRefreshInterval.allCases, id: \.self) { interval in
                    Text(interval == .manual ? "Manual" : "Every \(interval.rawValue) minutes").tag(interval)
                }
            }
            .disabled(!model.claudeFeedInstalled)
            Text("Checks account limits without sending a model prompt. Longer intervals mean older readings; Refresh Claude remains available.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var reserveThresholds: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeading(
                title: "Reserve thresholds",
                detail: "Warn before remaining capacity falls below your safety margin."
            )

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Color.clear.frame(width: 84, height: 1)
                    Text("Short window")
                    Text("Weekly")
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)

                GridRow {
                    Label("Codex", systemImage: "circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .symbolRenderingMode(.monochrome)
                    CompactReserveControl(title: "Codex short-window reserve", value: reserveBinding(\.codexShort))
                    CompactReserveControl(title: "Codex weekly reserve", value: reserveBinding(\.codexLong))
                }
                .foregroundStyle(Color.rationbookIndigo)

                GridRow {
                    Label("Claude", systemImage: "circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .symbolRenderingMode(.monochrome)
                    CompactReserveControl(title: "Claude short-window reserve", value: reserveBinding(\.claudeShort))
                    CompactReserveControl(title: "Claude weekly reserve", value: reserveBinding(\.claudeLong))
                }
                .foregroundStyle(Color.rationbookPurple)
            }
            .disabled(model.configuration.fixedReserveSettings != nil)
            .padding(10)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var alertsRow: some View {
        HStack(spacing: 10) {
            SettingsRowIcon(systemImage: "bell")
            VStack(alignment: .leading, spacing: 2) {
                Text("Reserve and stale-data alerts")
                    .font(.caption.weight(.medium))
                Text("Only notify for meaningful capacity events.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Reserve and stale-data alerts", isOn: Binding(
                get: { model.notificationsEnabled },
                set: { model.updateNotifications($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(.rationbookIndigo)
        }
    }

    private var windowVisibilitySection: some View {
        DisclosureGroup(isExpanded: $windowVisibilityExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if configurableProviders.isEmpty {
                    Text("Refresh \(model.configuration.appName) once to discover configurable quota windows.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(configurableProviders) { provider in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 7) {
                                ProviderMark(provider: provider.provider)
                                    .frame(width: 20, height: 20)
                                Text(providerDisplayName(provider.provider))
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text("\(configurableWindows(for: provider).count) windows")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            LazyVGrid(
                                columns: [GridItem(.flexible()), GridItem(.flexible())],
                                alignment: .leading,
                                spacing: 6
                            ) {
                                ForEach(configurableWindows(for: provider)) { window in
                                    Toggle(window.displayLabel, isOn: Binding(
                                        get: {
                                            model.isWindowVisible(
                                                providerID: provider.provider,
                                                windowID: window.id
                                            )
                                        },
                                        set: {
                                            model.updateWindowVisibility(
                                                providerID: provider.provider,
                                                windowID: window.id,
                                                visible: $0
                                            )
                                        }
                                    ))
                                    .toggleStyle(.checkbox)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .help("Controls display only. Window ID: \(window.id)")
                                }
                            }
                            .padding(.leading, 27)
                        }
                    }

                    if !model.windowDisplayPreferences.hiddenWindowKeys.isEmpty {
                        Button("Show all windows", action: model.showAllWindows)
                            .controlSize(.small)
                            .padding(.leading, 27)
                    }
                }
            }
            .padding(.top, 9)
        } label: {
            SettingsSectionHeading(
                title: "Visible quota windows",
                detail: "Choose the menu and breakdown rows. Collection, history, alerts, and CLI/API output keep every window."
            )
        }
    }

    private var appearanceRow: some View {
        HStack(spacing: 10) {
            SettingsRowIcon(systemImage: "circle.lefthalf.filled")
            VStack(alignment: .leading, spacing: 2) {
                Text("Appearance")
                    .font(.caption.weight(.medium))
                Text("Choose a theme or follow macOS.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Appearance", selection: Binding(
                get: { model.appearance },
                set: { model.updateAppearance($0) }
            )) {
                ForEach(RationbookAppearance.allCases) { value in
                    Text(value.label).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 182)
        }
    }

    private var launchAtLoginRow: some View {
        HStack(spacing: 10) {
            SettingsRowIcon(systemImage: "power")
            VStack(alignment: .leading, spacing: 2) {
                Text("Open at Login")
                    .font(.caption.weight(.medium))
                Text(model.launchAtLoginRequiresApproval ? "Approval required in Login Items." : "Keep capacity visible after signing in.")
                    .font(.caption2)
                    .foregroundStyle(model.launchAtLoginRequiresApproval ? Color.orange : Color.secondary)
            }
            Spacer()
            if model.launchAtLoginRequiresApproval {
                Button("Review…", action: model.openLoginItemsSettings)
                    .controlSize(.small)
            }
            Toggle("Open \(model.configuration.appName) at Login", isOn: Binding(
                get: { model.launchAtLoginEnabled },
                set: { model.updateLaunchAtLogin($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(.rationbookIndigo)
        }
    }

    private var historyRow: some View {
        HStack(spacing: 10) {
            SettingsRowIcon(systemImage: "clock.arrow.circlepath")
            VStack(alignment: .leading, spacing: 2) {
                Text("History")
                    .font(.caption.weight(.medium))
                Text("Stored locally and pruned automatically.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("History retention", selection: Binding(
                get: { model.retentionDays },
                set: { model.updateRetention($0) }
            )) {
                Text("30 days").tag(30)
                Text("60 days").tag(60)
                Text("90 days").tag(90)
                Text("Unlimited").tag(0)
            }
            .labelsHidden()
            .frame(width: 112)

            Label(model.isRefreshing ? "Refreshing" : "Showing latest observations", systemImage: "arrow.clockwise")
                .font(.caption2)
                .foregroundStyle(Color.secondary)

            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(model.isRefreshing)
            .accessibilityLabel("Refresh now")
        }
    }

    private var supportRow: some View {
        HStack(spacing: 10) {
            SettingsRowIcon(systemImage: "wrench.and.screwdriver")
            VStack(alignment: .leading, spacing: 2) {
                Text("Support")
                    .font(.caption.weight(.medium))
                Text("\(model.configuration.appName) \(appVersion) · diagnostics exclude quota and identity data.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Copy diagnostics", action: model.copyDiagnostics)
                .controlSize(.small)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? RationbookBuild.version
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? RationbookBuild.build
        return "\(version) (\(build))"
    }

    private var configurableProviders: [ProviderStatus] {
        model.envelope.providers
            .filter { !configurableWindows(for: $0).isEmpty }
            .sorted { providerOrder($0.provider) < providerOrder($1.provider) }
    }

    private func configurableWindows(for provider: ProviderStatus) -> [QuotaWindow] {
        HumanPresentation.visibleWindows(for: provider).sorted { lhs, rhs in
            if lhs.durationSeconds != rhs.durationSeconds {
                return (lhs.durationSeconds ?? Int.max) < (rhs.durationSeconds ?? Int.max)
            }
            return lhs.displayLabel.localizedCaseInsensitiveCompare(rhs.displayLabel) == .orderedAscending
        }
    }

    private func providerOrder(_ provider: String) -> Int {
        switch provider {
        case "openai": return 0
        case "anthropic": return 1
        default: return 2
        }
    }

    private func providerDisplayName(_ provider: String) -> String {
        provider == "openai" ? "OpenAI · Codex" : "Anthropic · Claude"
    }

    private var overallProviderState: ProviderState {
        HumanPresentation.overallState(for: model.envelope.providers)
    }

    private func providerState(_ id: String) -> ProviderState {
        guard let provider = model.envelope.providers.first(where: { $0.provider == id }) else { return .unavailable }
        return HumanPresentation.currentState(for: provider)
    }

    private var anthropicIntegrationDetail: String {
        return model.claudeFeedInstalled
            ? "Installed · reads Claude’s quota feed."
            : "Optional local, read-only feed; no Claude credential is read or stored."
    }

    private var anthropicActionTitle: String {
        model.claudeFeedInstalled ? "Remove" : "Enable"
    }

    private func reserveBinding(_ keyPath: WritableKeyPath<ReserveSettings, Double>) -> Binding<Double> {
        Binding(
            get: { model.reserveSettings[keyPath: keyPath] },
            set: { value in
                var settings = model.reserveSettings
                settings[keyPath: keyPath] = value
                model.updateReserve(settings)
            }
        )
    }
}

private struct SettingsSectionHeading: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct IntegrationRow: View {
    let provider: String
    let title: String
    let detail: String
    let state: ProviderState
    var actionTitle: String?
    var actionDisabled = false
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            ProviderMark(provider: provider)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.medium))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            ProviderStatePill(state: state)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .disabled(actionDisabled)
            }
        }
    }
}

private struct IntegrationFeedbackBanner: View {
    let message: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(message, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .combine)
    }
}

private struct SettingsRowIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
    }
}

private struct CompactReserveControl: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 0) {
            Button {
                value = max(0, value - 1)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 25, height: 25)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Decrease \(title)")

            Text("\(value, specifier: "%.0f")%")
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: 38)

            Button {
                value = min(50, value + 1)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 25, height: 25)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Increase \(title)")
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue("\(value, specifier: "%.0f") percent")
    }
}

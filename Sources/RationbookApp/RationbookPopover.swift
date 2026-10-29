// SPDX-License-Identifier: Apache-2.0

import AppKit
import RationbookCore
import SwiftUI

struct RationbookPopover: View {
    @ObservedObject var model: RationbookAppModel
    @Environment(\.openSettings) private var openSettings
    @AppStorage private var detailLevelRaw: String
    let maximumHeight: CGFloat
    let resize: (CGFloat) -> Void
    @State private var measuredHeights: [String: CGFloat] = [:]

    private var panelHeight: CGFloat {
        min(maximumHeight, measuredHeights.count == 3 ? measuredHeights.values.reduce(2, +) : maximumHeight)
    }

    init(model: RationbookAppModel, maximumHeight: CGFloat, resize: @escaping (CGFloat) -> Void) {
        self.maximumHeight = maximumHeight
        self.resize = resize
        self.model = model
        _detailLevelRaw = AppStorage(
            wrappedValue: RationbookDetailLevel.full.rawValue,
            "\(model.configuration.defaultsPrefix).detailLevel"
        )
    }

    private var detailLevel: RationbookDetailLevel {
        RationbookDetailLevel(rawValue: detailLevelRaw) ?? .full
    }

    private var openAI: ProviderStatus? {
        model.envelope.providers.first(where: { $0.provider == "openai" })
    }

    private var anthropic: ProviderStatus? {
        model.envelope.providers.first(where: { $0.provider == "anthropic" })
    }

    var body: some View {
        VStack(spacing: 0) {
            popoverHeader
                .background(heightMeasurement("header"))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let error = model.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 2)
                    }

                    if model.claudeNeedsSignIn {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Sign in to Claude to resume updates", systemImage: "person.crop.circle.badge.exclamationmark")
                                .font(.headline)
                            Text("Claude Code is signed out. Your previous readings are saved, but they do not show your current capacity.")
                                .font(.callout)
                            Button(model.waitingForClaude ? "Waiting for sign-in…" : "Sign in to Claude…") {
                                model.signInToClaude()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.waitingForClaude)
                            Text(model.waitingForClaude
                                 ? "Complete sign-in in Terminal, then enter /usage and press Esc after the percentages appear. This notice closes when a new reading arrives."
                                 : "Opens Claude Code in Terminal. Sign in with your Claude subscription to reconnect.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.orange.opacity(0.5), lineWidth: 1)
                        }
                    } else if let message = model.integrationMessage {
                        Label(message, systemImage: model.waitingForClaude ? "clock" : "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)
                    }

                    if let openAI {
                        CapacityProviderPanel(
                            provider: openAI,
                            history: model.history,
                            detailLevel: detailLevel,
                            displayPreferences: model.windowDisplayPreferences
                        )
                    }

                    if let anthropic {
                        if model.configuration.showsPublicIntegrations && model.claudeFeedInstalled && !model.claudeNeedsSignIn {
                            HStack {
                                Button(model.waitingForClaude ? "Refreshing Claude…" : "Refresh Claude") {
                                    model.refreshClaudeAutomatically(force: true)
                                }
                                Button("Open Claude in Terminal…") { model.refreshClaude() }
                            }
                            .disabled(model.waitingForClaude)
                            .buttonStyle(.link)
                            .help("Claude Code handles sign-in. Open Terminal if automatic refresh needs attention.")
                        }
                        if HumanPresentation.visibleWindows(for: anthropic).isEmpty,
                           model.configuration.showsPublicIntegrations {
                            ClaudeSetupRow(
                                provider: anthropic,
                                isFeedInstalled: model.claudeFeedInstalled
                            )
                        } else {
                            CapacityProviderPanel(
                                provider: anthropic,
                                history: model.history,
                                detailLevel: detailLevel,
                                displayPreferences: model.windowDisplayPreferences
                            )
                        }
                    }
                }
                .padding(12)
                .fixedSize(horizontal: false, vertical: true)
                .background(heightMeasurement("content"))
            }
            .scrollIndicators(.visible)

            Divider()
            popoverFooter
                .background(heightMeasurement("footer"))
        }
        .frame(height: panelHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .onPreferenceChange(PopoverHeightsKey.self) { measuredHeights = $0 }
        .onChange(of: panelHeight) { _, height in resize(height) }
        .onAppear {
            model.refreshOnOpen()
        }
    }

    private func heightMeasurement(_ section: String) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: PopoverHeightsKey.self, value: [section: geometry.size.height])
        }
    }

    private var popoverHeader: some View {
        HStack(spacing: 10) {
            RationbookSymbol(showsTile: true)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.configuration.appName)
                    .font(.headline)
                Text(model.configuration.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            ProviderStatePill(state: overallProviderState, compact: true)

            Picker("Detail", selection: Binding(
                get: { detailLevelRaw },
                set: { detailLevelRaw = $0 }
            )) {
                Text("Essential").tag(RationbookDetailLevel.essential.rawValue)
                Text("Full").tag(RationbookDetailLevel.full.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: 122)

            Button {
                model.refresh()
            } label: {
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: model.refreshFeedback == nil ? "arrow.clockwise" : "checkmark")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(model.isRefreshing)
            .accessibilityLabel("Refresh capacity")
            .help(model.configuration.refreshHelp)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var popoverFooter: some View {
        HStack {
            Button {
                openSettingsInForeground()
            } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.plain)

            Spacer()

            Label(
                model.isRefreshing ? "Refreshing…" : (model.refreshFeedback ?? readingsSummary),
                systemImage: model.isRefreshing ? "arrow.clockwise" : (overallProviderState == .available ? "checkmark" : "info.circle")
            )
            .foregroundStyle(Color.secondary)
            .lineLimit(1)

            Spacer()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func openSettingsInForeground() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openSettings()
        bringSettingsWindowForward(attemptsRemaining: 4)
    }

    private func bringSettingsWindowForward(attemptsRemaining: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApplication.shared.activate(ignoringOtherApps: true)
            if let settingsWindow = NSApplication.shared.windows.first(where: {
                $0.isVisible && $0.canBecomeKey && $0.title.localizedCaseInsensitiveContains("settings")
            }) {
                settingsWindow.makeKeyAndOrderFront(nil)
                settingsWindow.orderFrontRegardless()
            } else if attemptsRemaining > 0 {
                bringSettingsWindowForward(attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }

    private var readingsSummary: String {
        switch overallProviderState {
        case .available: "Current readings"
        case .partial: "Some readings need attention"
        case .stale: "Showing last known readings"
        default: "No current readings"
        }
    }

    private var overallProviderState: ProviderState {
        HumanPresentation.overallState(for: model.envelope.providers)
    }

}

private struct PopoverHeightsKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

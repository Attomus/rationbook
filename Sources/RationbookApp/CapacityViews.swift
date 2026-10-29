// SPDX-License-Identifier: Apache-2.0

import AppKit
import RationbookCore
import SwiftUI

struct CapacityProviderPanel: View {
    let provider: ProviderStatus
    let history: [WindowSample]
    let detailLevel: RationbookDetailLevel
    let displayPreferences: WindowDisplayPreferences

    @State private var showsHistory = false

    private var tint: Color {
        provider.provider == "openai" ? .rationbookIndigo : .rationbookPurple
    }

    private var title: String {
        provider.provider == "openai" ? "Codex" : "Claude"
    }

    private var availableWindows: [QuotaWindow] {
        HumanPresentation.currentWindows(for: provider)
    }

    private var visibleWindows: [QuotaWindow] {
        availableWindows.filter { displayPreferences.isVisible(providerID: provider.provider, windowID: $0.id) }.sorted { lhs, rhs in
            if lhs.id == provider.limitingWindowID { return true }
            if rhs.id == provider.limitingWindowID { return false }
            return (lhs.durationSeconds ?? Int.max) < (rhs.durationSeconds ?? Int.max)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                ProviderMark(provider: provider.provider)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(organization.uppercased())
                            .font(.caption2.weight(.bold))
                            .tracking(0.7)
                            .foregroundStyle(tint)
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                    }
                    if detailLevel == .full {
                        Text(providerMetadata)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()
                ProviderStatePill(state: HumanPresentation.currentState(for: provider))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(tint.opacity(0.075))

            if visibleWindows.isEmpty {
                Divider()
                Text(emptyWindowsMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(13)
            }

            if !visibleWindows.isEmpty {
                Divider()
                VStack(spacing: 4) {
                    ForEach(visibleWindows) { window in
                        CapacityWindowRow(
                            providerID: provider.provider,
                            window: window,
                            samples: history.filter { $0.provider == provider.provider && $0.windowID == window.id },
                            isLimiting: window.id == provider.limitingWindowID,
                            detailLevel: detailLevel,
                            tint: tint
                        )
                    }
                }
                .padding(4)
            }

            if provider.provider == "anthropic", !availableWindows.contains(where: { $0.scope == "model" }) {
                Divider()
                HStack(spacing: 10) {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model-specific weekly")
                            .font(.caption.weight(.medium))
                        Text("Not exposed by Claude Code's supported local quota feed")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Unknown")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.secondary.opacity(0.10), in: Capsule())
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
            }

            if HumanPresentation.currentState(for: provider) == .stale {
                Divider()
                Label(provider.provider == "anthropic"
                      ? "Last known usage only. Refresh Claude to check current capacity; use Terminal if sign-in is needed."
                      : "Last known usage only. Refresh capacity to check for a new reading.",
                      systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(13)
            }

            if detailLevel == .full, let diagnostic = provider.errors.first(where: {
                $0.code != "stale_observation"
                    && !($0.code == "quota_window_absent_after_reset"
                         && !HumanPresentation.historicalWindows(for: provider).isEmpty)
            }) {
                Divider()
                Label(diagnostic.message, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
            }

            let historical = HumanPresentation.historicalWindows(for: provider)
            if !historical.isEmpty {
                Divider()
                DisclosureGroup("Previous readings (\(historical.count))", isExpanded: $showsHistory) {
                    Text("Retained for reference; excluded from current capacity. Full history remains available through the CLI.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(historical) { window in
                        HStack {
                            Text(window.displayLabel)
                            Spacer()
                            Text("Last known \(Int(window.remainingPercent.rounded()))%")
                        }
                        .font(.caption)
                        Text(window.observedAt, style: .date)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .padding(13)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(tint.opacity(0.28), lineWidth: 1)
        }
    }

    private var organization: String {
        provider.provider == "openai" ? "OpenAI" : "Anthropic"
    }

    private var providerMetadata: String {
        let plan = provider.account?.plan.map { "\($0) plan · " } ?? ""
        let observed = availableWindows.map(\.observedAt).max().map {
            RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date())
        } ?? "never"
        let scope = provider.provider == "openai" ? "Account quota" : "Aggregate account"
        return "\(plan)\(scope) · observed \(observed)"
    }

    private var emptyWindowsMessage: String {
        if !availableWindows.isEmpty {
            return "All quota windows are hidden. Change Visible quota windows in Settings."
        }
        return provider.errors.first?.message ?? "No quota data"
    }
}

struct CapacityWindowRow: View {
    let providerID: String
    let window: QuotaWindow
    let samples: [WindowSample]
    let isLimiting: Bool
    let detailLevel: RationbookDetailLevel
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(window.displayLabel)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        if isLimiting {
                            Text("Limiting")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(tint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(tint.opacity(0.11), in: Capsule())
                        }
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(window.remainingPercent, specifier: "%.0f")%")
                            .font(.title3.monospacedDigit().weight(.semibold))
                        Text([.stale, .unknown].contains(window.freshness) ? "last known remaining" : "remaining")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if samples.count >= 2 {
                    CapacitySparkline(
                        samples: samples,
                        tint: tint,
                        resetObservedAt: window.resetObservedAt
                    )
                        .frame(width: 104, height: 34)
                        .accessibilityLabel("Recent remaining capacity for \(window.displayLabel)")
                }
            }

            CapacityPaceBar(
                remainingPercent: window.remainingPercent,
                targetPercent: pace?.targetRemainingPercent,
                tint: progressTint,
                label: window.displayLabel
            )

            HStack(spacing: 10) {
                Label(resetText, systemImage: "clock")
                    .lineLimit(1)
                    .foregroundStyle(resetTimeHasPassed ? Color.orange : Color.secondary)
                Spacer(minLength: 4)
                if let policy = window.policy {
                    switch policy.state {
                    case .available:
                        Label("\(policy.safeRemainingPercent, specifier: "%.0f")% safe after reserve", systemImage: "checkmark.shield")
                            .foregroundStyle(Color.green)
                    case .exhausted:
                        Label("Reserve reached", systemImage: "exclamationmark.shield")
                            .foregroundStyle(Color.red)
                    case .uncertain, .unavailable:
                        Label("Last observed · capacity uncertain", systemImage: "questionmark.circle")
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if detailLevel == .full {
                HStack(alignment: .top, spacing: 12) {
                    DiagnosticMetric(title: "Pace", value: paceText, detail: paceDetail, valueTint: paceTint)
                    DiagnosticMetric(title: "Usage rate", value: usageRateText, detail: usageRateDetail)
                    DiagnosticMetric(
                        title: "Forecast",
                        value: forecastTitle,
                        detail: forecastDetail,
                        valueTint: forecastTint
                    )
                }
            }

            if detailLevel == .full, let resetObserved = window.resetObservedAt {
                Label(
                    "Reset observed \(RelativeDateTimeFormatter().localizedString(for: resetObserved, relativeTo: Date()))",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isLimiting ? tint.opacity(0.28) : Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private var pace: WindowPace? {
        PaceEstimator.estimate(window: window)
    }

    private var rowBackground: Color {
        if isLimiting { return tint.opacity(0.055) }
        return Color(nsColor: .windowBackgroundColor).opacity(0.48)
    }

    private var progressTint: Color {
        switch ReservePolicy.capacityRisk(for: window) {
        case .normal: return tint
        case .warning: return .orange
        case .critical: return .red
        case .uncertain: return .gray
        }
    }

    private var resetText: String {
        guard let reset = window.expectedResetsAt else { return "Reset schedule unavailable" }
        let relative = RelativeDateTimeFormatter().localizedString(for: reset, relativeTo: Date())
        if resetTimeHasPassed {
            let source = providerID == "anthropic" ? "Claude" : "provider"
            return "Reset due \(relative) · awaiting \(source) update"
        }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE HH:mm")
        let absolute = formatter.string(from: reset)
        return "Resets \(relative) · \(absolute)"
    }

    private var resetTimeHasPassed: Bool {
        guard let reset = window.expectedResetsAt else { return false }
        return reset <= Date()
    }

    private var paceText: String {
        guard let pace else { return "Unavailable" }
        switch pace.status {
        case .ahead:
            return String(format: "%.0f%% ahead", abs(pace.deltaPercent))
        case .onPace:
            return "On pace"
        case .behind:
            return String(format: "%.0f%% behind", abs(pace.deltaPercent))
        }
    }

    private var paceDetail: String {
        guard let pace else { return paceUnavailableReason }
        return String(format: "Target %.0f%% remaining", pace.targetRemainingPercent)
    }

    private var paceTint: Color {
        guard let pace else { return .secondary }
        switch pace.status {
        case .ahead: return .green
        case .onPace: return .primary
        case .behind: return .orange
        }
    }

    private var paceUnavailableReason: String {
        if window.freshness == .stale || window.freshness == .unknown { return "Latest reading not fresh" }
        if window.dataQuality == .inferred { return "Needs explicit reset timing" }
        if window.durationSeconds == nil { return "Window duration unavailable" }
        if window.expectedResetsAt == nil || resetTimeHasPassed { return "Reset schedule unavailable" }
        return "Reserve unavailable"
    }

    private var usageRateText: String {
        guard let rate = window.observedRate else { return "—" }
        return String(format: "%.1f%%/h", rate.forecastBurnPPPerWallHour)
    }

    private var usageRateDetail: String {
        let sustainable = pace.map { String(format: "sustainable %.1f%%/h", $0.sustainablePercentPerHour) }
        guard let rate = window.observedRate else { return sustainable?.capitalized ?? "Not enough history" }
        let confidence = "\(rate.confidence.rawValue.capitalized) confidence"
        return sustainable.map { "\(confidence) · \($0)" } ?? "\(confidence) · \(rate.sampleCount) samples"
    }

    private var forecastTitle: String {
        guard let scenario = window.reserveScenario else { return "Unavailable" }
        return scenario.firstEvent == "expected_reset" ? "Safe until reset" : "Reserve at risk"
    }

    private var forecastDetail: String {
        if let scenario = window.reserveScenario {
            if scenario.firstEvent == "expected_reset", let hours = scenario.hoursUntilExpectedReset {
                return "Reset in \(formatHours(hours))"
            }
            return "Reserve in \(formatHours(scenario.hoursUntilReserve))"
        }
        guard let reason = window.forecastUnavailableReason else { return "No forecast evidence" }
        let text = reason.replacingOccurrences(of: "_", with: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private var forecastTint: Color {
        guard let scenario = window.reserveScenario else { return .secondary }
        return scenario.firstEvent == "expected_reset" ? .green : .orange
    }

    private func formatHours(_ hours: Double) -> String {
        if hours >= 48 { return String(format: "%.1fd", hours / 24) }
        return String(format: "%.1fh", hours)
    }
}

struct DiagnosticMetric: View {
    let title: String
    let value: String
    let detail: String
    let valueTint: Color

    init(title: String, value: String, detail: String, valueTint: Color = .primary) {
        self.title = title
        self.value = value
        self.detail = detail
        self.valueTint = valueTint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(valueTint)
                .lineLimit(1)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CapacityPaceBar: View {
    let remainingPercent: Double
    let targetPercent: Double?
    let tint: Color
    let label: String

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: 8)
                Capsule()
                    .fill(tint)
                    .frame(width: width * CGFloat(clampedRemaining / 100), height: 8)
                if let targetPercent {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color.primary.opacity(0.8))
                        .frame(width: 2, height: 12)
                        .offset(x: markerOffset(for: width, targetPercent: targetPercent))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 12)
        .help(helpText)
        .accessibilityLabel("\(label) remaining capacity")
        .accessibilityValue(accessibilityValue)
    }

    private var clampedRemaining: Double {
        min(max(remainingPercent, 0), 100)
    }

    private func markerOffset(for width: CGFloat, targetPercent: Double) -> CGFloat {
        let target = min(max(targetPercent, 0), 100)
        return min(max(1, width * CGFloat(target / 100) - 1), max(1, width - 3))
    }

    private var helpText: String {
        guard let targetPercent else { return String(format: "%.0f%% remaining", clampedRemaining) }
        return String(format: "%.0f%% remaining · pace marker %.0f%%", clampedRemaining, targetPercent)
    }

    private var accessibilityValue: String {
        guard let targetPercent else { return String(format: "%.0f percent", clampedRemaining) }
        return String(
            format: "%.0f percent; pace target %.0f percent remaining",
            clampedRemaining,
            targetPercent
        )
    }
}

struct CapacitySparkline: View {
    let samples: [WindowSample]
    let tint: Color
    let resetObservedAt: Date?

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            ZStack {
                RemainingSparklineArea(samples: displaySamples, resetObservedAt: resetObservedAt)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.22), tint.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                RemainingSparkline(samples: displaySamples, resetObservedAt: resetObservedAt)
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            }
            .frame(height: 23)

            Text(trendLabel)
                .font(.system(size: 8, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(helpText)
        .accessibilityValue(helpText)
    }

    private var displaySamples: [WindowSample] {
        let sorted = samples.sorted { $0.lastObservedAt < $1.lastObservedAt }
        guard let latest = sorted.last else { return [] }
        let cutoff = latest.lastObservedAt.addingTimeInterval(-86_400)
        let recent = sorted.filter { $0.lastObservedAt >= cutoff }
        return recent.count >= 2 ? recent : Array(sorted.suffix(2))
    }

    private var trendLabel: String {
        guard let first = displaySamples.first, let last = displaySamples.last else { return "Recent trend" }
        if let event = latestDiscontinuity {
            let postEventDelta = last.remainingPercent - displaySamples[event.index].remainingPercent
            if abs(postEventDelta) < 0.5 {
                return event.confirmed ? "Reset observed" : "Capacity jump"
            }
            let formatted = signedPercent(postEventDelta)
            return event.confirmed ? "Since reset \(formatted)" : "After jump \(formatted)"
        }
        let delta = last.remainingPercent - first.remainingPercent
        return "Trend \(signedPercent(delta))"
    }

    private var helpText: String {
        let values = displaySamples.map(\.remainingPercent)
        guard let first = values.first,
              let last = values.last,
              let domain = TrendScale.domain(values: values) else { return "Recent remaining-capacity trend" }
        let eventDescription: String
        if let event = latestDiscontinuity {
            eventDescription = event.confirmed
                ? " · reset rendered as an instantaneous step"
                : " · capacity jump rendered as an instantaneous step"
        } else {
            eventDescription = ""
        }
        let scale = String(
            format: "Recent trend %.0f%% to %.0f%% remaining · chart scale %.0f–%.0f%%",
            first,
            last,
            domain.lowerBound,
            domain.upperBound
        )
        return scale + eventDescription
    }

    private var latestDiscontinuity: (index: Int, confirmed: Bool)? {
        guard displaySamples.count >= 2 else { return nil }
        for index in stride(from: displaySamples.count - 1, through: 1, by: -1) {
            let previous = displaySamples[index - 1]
            let current = displaySamples[index]
            guard TrendScale.isUpwardDiscontinuity(
                previous: previous.remainingPercent,
                current: current.remainingPercent
            ) else { continue }
            let confirmed = TrendScale.resetEventDate(
                between: previous.lastObservedAt,
                and: current.lastObservedAt,
                scheduledAt: previous.expectedResetsAt,
                observedAt: resetObservedAt
            ) != nil
            return (index, confirmed)
        }
        return nil
    }

    private func signedPercent(_ value: Double) -> String {
        guard abs(value) >= 0.5 else { return "0%" }
        return String(format: "%+.0f%%", value).replacingOccurrences(of: "-", with: "−")
    }
}

struct RemainingSparkline: Shape {
    let samples: [WindowSample]
    let resetObservedAt: Date?

    func path(in rect: CGRect) -> Path {
        sparklinePath(samples: samples, resetObservedAt: resetObservedAt, rect: rect, closesArea: false)
    }
}

struct RemainingSparklineArea: Shape {
    let samples: [WindowSample]
    let resetObservedAt: Date?

    func path(in rect: CGRect) -> Path {
        sparklinePath(samples: samples, resetObservedAt: resetObservedAt, rect: rect, closesArea: true)
    }
}

private func sparklinePath(
    samples: [WindowSample],
    resetObservedAt: Date?,
    rect: CGRect,
    closesArea: Bool
) -> Path {
    let samples = samples.sorted { $0.lastObservedAt < $1.lastObservedAt }
    let values = samples.map(\.remainingPercent)
    guard values.count >= 2, let domain = TrendScale.domain(values: values) else { return Path() }
    let inset = rect.insetBy(dx: 2, dy: 3)
    let firstTime = samples[0].lastObservedAt
    let lastTime = samples[samples.count - 1].lastObservedAt
    let timeSpan = lastTime.timeIntervalSince(firstTime)

    func xPosition(for date: Date, index: Int) -> CGFloat {
        guard timeSpan > 0 else {
            return inset.minX + inset.width * CGFloat(index) / CGFloat(samples.count - 1)
        }
        let fraction = min(max(date.timeIntervalSince(firstTime) / timeSpan, 0), 1)
        return inset.minX + inset.width * CGFloat(fraction)
    }

    func yPosition(for value: Double) -> CGFloat {
        inset.maxY - inset.height * CGFloat(domain.position(for: value))
    }

    var path = Path()
    path.move(to: CGPoint(x: inset.minX, y: yPosition(for: values[0])))
    for index in 1..<samples.count {
        let previous = samples[index - 1]
        let current = samples[index]
        let currentX = xPosition(for: current.lastObservedAt, index: index)
        let currentY = yPosition(for: current.remainingPercent)
        if TrendScale.isUpwardDiscontinuity(
            previous: previous.remainingPercent,
            current: current.remainingPercent
        ) {
            let event = TrendScale.resetEventDate(
                between: previous.lastObservedAt,
                and: current.lastObservedAt,
                scheduledAt: previous.expectedResetsAt,
                observedAt: resetObservedAt
            )
            let eventX = xPosition(for: event ?? current.lastObservedAt, index: index)
            path.addLine(to: CGPoint(x: eventX, y: yPosition(for: previous.remainingPercent)))
            path.addLine(to: CGPoint(x: eventX, y: currentY))
        }
        path.addLine(to: CGPoint(x: currentX, y: currentY))
    }
    if closesArea {
        path.addLine(to: CGPoint(x: inset.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: inset.minX, y: rect.maxY))
        path.closeSubpath()
    }
    return path
}

struct ClaudeSetupRow: View {
    let provider: ProviderStatus
    let isFeedInstalled: Bool

    var body: some View {
        HStack(spacing: 10) {
            ProviderMark(provider: "anthropic")
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            ProviderStatePill(state: effectiveState)
        }
        .padding(11)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        }
    }

    private var effectiveState: ProviderState {
        if provider.errors.contains(where: { $0.code == "waiting_for_observation" }) {
            return .waitingForObservation
        }
        return provider.state
    }

    private var message: String {
        if isFeedInstalled {
            return "Local feed installed · choose Refresh Claude in Terminal"
        }
        return provider.errors.first?.message ?? "Enable the local Claude Code quota feed in Settings"
    }
}

struct ProviderMark: View {
    let provider: String

    var body: some View {
        Image(systemName: provider == "openai" ? "terminal" : "sparkles")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(provider == "openai" ? Color.rationbookIndigo : Color.rationbookPurple)
            .frame(width: 30, height: 30)
            .background(
                (provider == "openai" ? Color.rationbookIndigo : Color.rationbookPurple).opacity(0.11),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
    }
}

struct ProviderStatePill: View {
    let state: ProviderState
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            if !compact || state != .available {
                Text(label)
            } else {
                Text("Current")
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(color.opacity(0.11), in: Capsule())
        .accessibilityLabel(label)
    }

    private var label: String {
        switch state {
        case .available: "Available"
        case .partial: "Partial"
        case .stale: "Stale"
        case .unavailable: "Unavailable"
        case .missing: "Not installed"
        case .loggedOut: "Signed out"
        case .unsupported: "Unsupported"
        case .waitingForObservation: "Waiting"
        }
    }

    private var color: Color {
        switch state {
        case .available: .green
        case .partial, .stale, .waitingForObservation: .orange
        case .unavailable, .missing, .loggedOut, .unsupported: .secondary
        }
    }
}

// SPDX-License-Identifier: Apache-2.0

import AppKit
import RationbookCore
import SwiftUI

extension Color {
    static let rationbookInk = Color(red: 0.12, green: 0.16, blue: 0.31)
    static let rationbookIndigo = Color(red: 0.29, green: 0.36, blue: 0.78)
    static let rationbookPurple = Color(red: 0.49, green: 0.34, blue: 0.76)
    static let rationbookAccent = Color(red: 0.78, green: 0.96, blue: 0.38)
}

struct RationbookSymbol: View {
    let showsTile: Bool

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let originX = (geometry.size.width - size) / 2
            let originY = (geometry.size.height - size) / 2
            let symbolColor = showsTile ? Color.white : Color.primary

            ZStack {
                if showsTile {
                    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.rationbookIndigo, .rationbookInk],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(alignment: .topTrailing) {
                            Circle()
                                .fill(.white.opacity(0.22))
                                .frame(width: size * 0.52, height: size * 0.52)
                                .blur(radius: size * 0.15)
                                .offset(x: size * 0.12, y: -size * 0.13)
                                .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                                .stroke(.white.opacity(0.24), lineWidth: 1)
                                .padding(1)
                        }
                        .shadow(color: .rationbookIndigo.opacity(0.24), radius: 8, y: 4)
                }

                RoundedRectangle(cornerRadius: size * 0.07, style: .continuous)
                    .stroke(symbolColor, lineWidth: max(1.5, size * 0.055))
                    .frame(width: size * 0.57, height: size * 0.58)

                Path { path in
                    path.move(to: CGPoint(x: originX + size * 0.37, y: originY + size * 0.23))
                    path.addLine(to: CGPoint(x: originX + size * 0.37, y: originY + size * 0.77))
                    path.move(to: CGPoint(x: originX + size * 0.47, y: originY + size * 0.37))
                    path.addLine(to: CGPoint(x: originX + size * 0.70, y: originY + size * 0.37))
                    path.move(to: CGPoint(x: originX + size * 0.47, y: originY + size * 0.50))
                    path.addLine(to: CGPoint(x: originX + size * 0.64, y: originY + size * 0.50))
                    path.move(to: CGPoint(x: originX + size * 0.47, y: originY + size * 0.63))
                    path.addLine(to: CGPoint(x: originX + size * 0.57, y: originY + size * 0.63))
                }
                .stroke(symbolColor, style: StrokeStyle(lineWidth: max(1.25, size * 0.045), lineCap: .round))

                RoundedRectangle(cornerRadius: size * 0.025, style: .continuous)
                    .fill(showsTile ? Color.rationbookAccent : symbolColor)
                    .frame(width: max(2, size * 0.085), height: max(2, size * 0.13))
                    .position(x: originX + size * 0.66, y: originY + size * 0.245)
            }
        }
        .accessibilityHidden(true)
    }
}

enum MenuBarGaugeRenderer {
    private struct Item {
        let providerName: String
        let window: QuotaWindow

        var remainingPercent: Double { min(max(window.remainingPercent, 0), 100) }
        var reservePercent: Double? {
            window.policy.map { min(max($0.reservePercent, 0), 100) }
        }
        var risk: CapacityRisk { ReservePolicy.capacityRisk(for: window) }
        var spokenLabel: String {
            let state = switch risk {
            case .normal: ""
            case .warning: ", approaching reserve"
            case .critical: ", reserve reached"
            case .uncertain: ", last known reading; open Rationbook to refresh"
            }
            return "\(providerName) \(window.displayLabel), \(Int(remainingPercent.rounded())) percent remaining\(state)"
        }
    }

    static func image(
        providers: [ProviderStatus],
        displayPreferences: WindowDisplayPreferences,
        appName: String
    ) -> NSImage {
        let groups = gaugeGroups(providers: providers, displayPreferences: displayPreferences)
        guard !groups.isEmpty else {
            return NSImage(
                systemSymbolName: "gauge.with.dots.needle.50percent",
                accessibilityDescription: appName
            ) ?? NSImage(size: NSSize(width: 18, height: 18))
        }

        let gaugeSize: CGFloat = 20
        let gaugeSpacing: CGFloat = 3
        let groupSpacing: CGFloat = 9
        let width = groups.enumerated().reduce(CGFloat.zero) { total, entry in
            let groupWidth = CGFloat(entry.element.count) * gaugeSize
                + CGFloat(max(0, entry.element.count - 1)) * gaugeSpacing
            return total + groupWidth + (entry.offset == 0 ? 0 : groupSpacing)
        }
        let image = NSImage(size: NSSize(width: width, height: gaugeSize), flipped: false) { _ in
            var x: CGFloat = 0
            for (groupIndex, group) in groups.enumerated() {
                if groupIndex > 0 {
                    NSColor.labelColor.withAlphaComponent(0.48).setStroke()
                    let separator = NSBezierPath()
                    separator.lineWidth = 1.25
                    separator.lineCapStyle = .round
                    separator.move(to: NSPoint(x: x + groupSpacing / 2, y: 4))
                    separator.line(to: NSPoint(x: x + groupSpacing / 2, y: gaugeSize - 4))
                    separator.stroke()
                    x += groupSpacing
                }

                for (itemIndex, item) in group.enumerated() {
                    if itemIndex > 0 { x += gaugeSpacing }
                    drawGauge(item, in: NSRect(x: x, y: 0, width: gaugeSize, height: gaugeSize))
                    x += gaugeSize
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    static func accessibilityLabel(
        providers: [ProviderStatus],
        displayPreferences: WindowDisplayPreferences,
        appName: String
    ) -> String {
        let labels = gaugeGroups(providers: providers, displayPreferences: displayPreferences)
            .flatMap { $0 }
            .map(\.spokenLabel)
        return labels.isEmpty ? "\(appName), no capacity observations" : labels.joined(separator: "; ")
    }

    private static func gaugeGroups(
        providers: [ProviderStatus],
        displayPreferences: WindowDisplayPreferences
    ) -> [[Item]] {
        let claude = providers.first(where: { $0.provider == "anthropic" }).map {
            menuWindows(
                for: $0,
                limit: 2,
                prioritizesLimiting: false,
                displayPreferences: displayPreferences
            ).map {
                Item(providerName: "Claude", window: $0)
            }
        } ?? []
        let codex = providers.first(where: { $0.provider == "openai" }).map {
            menuWindows(
                for: $0,
                limit: 1,
                prioritizesLimiting: true,
                displayPreferences: displayPreferences
            ).map {
                Item(providerName: "Codex", window: $0)
            }
        } ?? []
        return [claude, codex].filter { !$0.isEmpty }
    }

    private static func menuWindows(
        for provider: ProviderStatus,
        limit: Int,
        prioritizesLimiting: Bool,
        displayPreferences: WindowDisplayPreferences
    ) -> [QuotaWindow] {
        let windows = displayPreferences.visibleWindows(for: provider)
            .filter { $0.scope == "account" }
            .sorted { lhs, rhs in
                if prioritizesLimiting {
                    if lhs.id == provider.limitingWindowID { return true }
                    if rhs.id == provider.limitingWindowID { return false }
                }
                if lhs.durationSeconds != rhs.durationSeconds {
                    return (lhs.durationSeconds ?? Int.max) < (rhs.durationSeconds ?? Int.max)
                }
                return lhs.displayLabel < rhs.displayLabel
            }
        return Array(windows.prefix(limit))
    }

    private static func drawGauge(_ item: Item, in rect: NSRect) {
        let isCritical = item.risk == .critical
        let circleInset: CGFloat = isCritical ? 2.25 : 1.25
        let circleRect = rect.insetBy(dx: circleInset, dy: circleInset)

        if isCritical {
            let halo = NSBezierPath(ovalIn: rect.insetBy(dx: 0.65, dy: 0.65))
            halo.lineWidth = 1.3
            NSColor.systemRed.withAlphaComponent(0.95).setStroke()
            halo.stroke()
        }

        let background = NSBezierPath(ovalIn: circleRect)
        background.lineWidth = 1.7
        background.lineCapStyle = .round
        background.setLineDash([2.2, 2.2], count: 2, phase: 0)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.62).setStroke()
        background.stroke()

        if item.remainingPercent > 0 {
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let arc = NSBezierPath()
            arc.lineWidth = 1.9
            arc.lineCapStyle = .round
            arc.appendArc(
                withCenter: center,
                radius: circleRect.width / 2,
                startAngle: 90,
                endAngle: 90 - item.remainingPercent * 3.6,
                clockwise: true
            )
            gaugeColor(for: item.risk).setStroke()
            arc.stroke()
        }

        if let reservePercent = item.reservePercent, reservePercent > 0 {
            drawReserveZone(reservePercent, in: circleRect)
        }

        let value = "\(Int(item.remainingPercent.rounded()))" as NSString
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: item.remainingPercent >= 99.5 ? 6.5 : 8,
            weight: .semibold
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: gaugeColor(for: item.risk),
        ]
        let size = value.size(withAttributes: attributes)
        value.draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    private static func gaugeColor(for risk: CapacityRisk) -> NSColor {
        switch risk {
        case .normal: return .labelColor
        case .warning: return .systemOrange
        case .critical: return .systemRed
        case .uncertain: return .systemOrange
        }
    }

    private static func drawReserveZone(_ reservePercent: Double, in circleRect: NSRect) {
        let center = NSPoint(x: circleRect.midX, y: circleRect.midY)
        let radius = circleRect.width / 2 + 0.25
        let endAngle = 90 - reservePercent * 3.6
        let zone = NSBezierPath()
        zone.lineWidth = 1.05
        zone.lineCapStyle = .round
        zone.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 90,
            endAngle: endAngle,
            clockwise: true
        )
        NSColor.systemRed.withAlphaComponent(0.72).setStroke()
        zone.stroke()

        let radians = endAngle * .pi / 180
        let tick = NSBezierPath()
        tick.lineWidth = 1.15
        tick.lineCapStyle = .round
        tick.move(to: NSPoint(
            x: center.x + cos(radians) * (radius - 1.5),
            y: center.y + sin(radians) * (radius - 1.5)
        ))
        tick.line(to: NSPoint(
            x: center.x + cos(radians) * (radius + 0.7),
            y: center.y + sin(radians) * (radius + 0.7)
        ))
        tick.stroke()
    }
}

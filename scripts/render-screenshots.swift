// SPDX-License-Identifier: Apache-2.0

import AppKit
import RationbookCore
import SwiftUI

@main
struct Capture {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let template = RationbookUIConfiguration.publicRationbook
        let config = RationbookUIConfiguration(appName: template.appName, subtitle: template.subtitle,
            defaultsPrefix: "dev.attomus.screenshot-fixture", showsPublicIntegrations: true,
            privacySummary: template.privacySummary, anthropicRefreshDescription: template.anthropicRefreshDescription,
            refreshHelp: template.refreshHelp, serviceFactory: { throw CocoaError(.fileNoSuchFile) })
        let model = RationbookAppModel(configuration: config)
        model.lastError = nil
        model.claudeFeedInstalled = true
        let now = Date()
        var providers: [ProviderStatus] = []
        for (id, label, values) in [("openai", "Codex", [32.0, 18.0]), ("anthropic", "Claude", [24.0, 41.0])] {
            let windows = values.enumerated().map { index, value in
                QuotaWindow(id: "\(id):\(index)", displayLabel: index == 0 ? "5 hour" : "7 day",
                    durationSeconds: index == 0 ? 18_000 : 604_800, observedAt: now, freshness: .fresh,
                    usedPercent: value, expectedResetsAt: now.addingTimeInterval(index == 0 ? 7_200 : 345_600),
                    dataQuality: id == "openai" ? .authoritative : .localObserved)
            }
            providers.append(ReservePolicy.apply(to: ProviderStatus(provider: id, agentLabel: label, state: .available,
                capabilities: AdapterCapabilities(supportsOnDemandRefresh: id == "openai", supportsPushUpdates: true),
                source: SourceMetadata(name: "synthetic screenshot fixture", documentation: "local", maturity: "fixture"),
                windows: windows), settings: model.reserveSettings))
        }
        for providerIndex in providers.indices {
            for windowIndex in providers[providerIndex].windows.indices {
                let window = providers[providerIndex].windows[windowIndex]
                var samples: [WindowSample] = []
                for index in 0..<8 {
                    let date = now.addingTimeInterval(Double(index - 7) * 900)
                    let used = window.usedPercent - Double(7 - index)
                    let object: [String: Any] = ["provider": providers[providerIndex].provider, "window_id": window.id,
                        "used_percent": used, "remaining_percent": 100 - used,
                        "first_observed_at": ISO8601DateFormatter().string(from: date),
                        "last_observed_at": ISO8601DateFormatter().string(from: date),
                        "sample_count": 1, "freshness": "fresh"]
                    samples.append(try RationbookJSON.decoder().decode(WindowSample.self,
                        from: JSONSerialization.data(withJSONObject: object)))
                }
                model.history += samples
                if let rate = BurnRateEstimator.estimate(samples: samples, now: now) {
                    providers[providerIndex].windows[windowIndex].observedRate = rate
                    providers[providerIndex].windows[windowIndex].reserveScenario = BurnRateEstimator.scenario(window: window, rate: rate, now: now)
                }
            }
        }
        model.envelope = StatusEnvelope(providers: providers)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, appearance, detail) in [
            ("rationbook-essential-light.png", RationbookAppearance.light, "essential"),
            ("rationbook-full-dark.png", RationbookAppearance.dark, "full"),
            ("rationbook-settings-dark.png", RationbookAppearance.dark, "settings"),
            ("rationbook-menubar.png", RationbookAppearance.light, "menubar")
        ] {
            model.appearance = appearance
            app.appearance = NSAppearance(named: appearance == .light ? .aqua : .darkAqua)
            UserDefaults.standard.set(detail, forKey: "\(config.defaultsPrefix).detailLevel")
            let view: AnyView
            if detail == "menubar" {
                var uncertain = providers
                for index in uncertain[0].windows.indices {
                    uncertain[0].windows[index].freshness = .stale
                }
                uncertain[0].state = .stale
                view = AnyView(VStack(alignment: .leading, spacing: 18) {
                    ForEach([false, true], id: \.self) { stale in
                        HStack {
                            Text(stale ? "Uncertain Codex reading" : "Current observations")
                                .font(.system(size: 13))
                            Spacer()
                            Image(nsImage: MenuBarGaugeRenderer.image(
                                providers: stale ? uncertain : providers,
                                displayPreferences: WindowDisplayPreferences(), appName: "Rationbook"))
                        }
                    }
                }.padding(20).frame(width: 360, height: 110)
                    .background(Color(nsColor: .windowBackgroundColor)))
            } else if detail == "settings" {
                view = AnyView(RationbookSettingsView(model: model).frame(width: 620, height: 900))
            } else {
                view = AnyView(RationbookPopover(model: model).frame(width: 520))
            }
            let host = NSHostingView(rootView: view.environment(\.colorScheme, appearance == .light ? .light : .dark))
            let size = detail == "menubar" ? NSSize(width: 360, height: 110)
                : detail == "settings" ? NSSize(width: 620, height: 900)
                : NSSize(width: 520, height: detail == "full" ? 750 : 570)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.setContentSize(size)
            window.orderFrontRegardless()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            host.layoutSubtreeIfNeeded()
            let fitting = host.fittingSize
            if detail == "essential" || detail == "full" { window.setContentSize(NSSize(width: 520, height: fitting.height)) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
            try png.write(to: output.appendingPathComponent(name))
            print("\(name): \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
            window.orderOut(nil)
        }
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "Capture")
    }
}

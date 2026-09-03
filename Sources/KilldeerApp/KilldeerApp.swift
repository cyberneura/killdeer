import AppKit
import SwiftUI

@main
struct KilldeerApp: App {
    @StateObject private var monitor = ProcessMonitor()
    @StateObject private var loginItem = LoginItemController()

    // Built once. The label is rebuilt on every published change from the
    // monitor, and rasterising the glyph each time would redraw it several
    // times a minute for an image that never changes.
    private static let restingIcon = KilldeerBird.menuBarImage(tint: nil)
    private static let warningIcon = KilldeerBird.menuBarImage(tint: .systemRed)

    var body: some Scene {
        MenuBarExtra {
            KilldeerMenu(monitor: monitor, loginItem: loginItem)
        } label: {
            // Colour is the whole signal, as DESIGN.md asks for: the bird stays
            // the bird and turns red. Swapping in a warning triangle would put
            // a second, unrelated shape in the menu bar for the state that
            // matters most, which is the worst moment to make someone re-read
            // the icon.
            Image(nsImage: monitor.hasRunaways ? Self.warningIcon : Self.restingIcon)
                .accessibilityLabel(monitor.hasRunaways ? "Killdeer warning" : "Killdeer")
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct KilldeerMenu: View {
    @ObservedObject var monitor: ProcessMonitor
    @ObservedObject var loginItem: LoginItemController

    var body: some View {
        Text(monitor.statusText)

        Button("Scan Now") {
            monitor.scanNow()
        }
        .disabled(monitor.isScanning)

        if !monitor.findings.isEmpty {
            Divider()
            ForEach(monitor.findings, id: \.process.identity) { finding in
                Button {
                    monitor.toggleSelection(finding.process.identity)
                } label: {
                    let selected = monitor.selected.contains(finding.process.identity)
                    Text("\(selected ? "✓" : "  ") \(finding.process.name) — PID \(finding.process.identity.pid), \(finding.cpuPercent, specifier: "%.1f")% CPU")
                }
            }

            Menu("Kill Selected…") {
                Button("Confirm Kill \(monitor.selected.count) Process\(monitor.selected.count == 1 ? "" : "es")") {
                    monitor.killSelected()
                }
            }
            .disabled(monitor.selected.isEmpty || monitor.isWorking)
        }

        Menu("Clean Orphan Chrome…") {
            Text("Scans for disconnected Chrome helpers")
            Button("Scan and Terminate Orphans") {
                monitor.cleanOrphanChrome()
            }
        }
        .disabled(monitor.isWorking)

        Divider()

        if loginItem.isAvailable {
            Toggle("Start at Login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))

            // Registering an app the user has previously denied does not fail;
            // it leaves the service waiting for approval that can only be given
            // in System Settings. Without this the toggle would simply refuse
            // to stay on, with nothing said about why.
            if loginItem.status == .requiresApproval {
                Button("Approve in System Settings…") {
                    loginItem.openSystemSettings()
                }
            }

            if let error = loginItem.lastError {
                Text("Start at Login failed: \(error)")
            }
        }

        Button("Settings…") {
            monitor.showSettingsPlaceholder()
        }

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }
}

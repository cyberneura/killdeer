import AppKit
import KilldeerCore
import SwiftUI

@main
struct KilldeerApp: App {
    @StateObject private var monitor = ProcessMonitor()
    @StateObject private var loginItem = LoginItemController()

    // Built once, one image per meter level and state. The label is rebuilt
    // on every published change from the monitor, and rasterising the glyph
    // each time would redraw it several times a minute; with the meter
    // quantised to CPUMeter.steps there are only a couple of dozen images it
    // can ever be.
    private static let restingIcons = icons(tint: nil)
    private static let warningIcons = icons(tint: .systemRed)

    private static func icons(tint: NSColor?) -> [NSImage] {
        (0...CPUMeter.steps).map {
            KilldeerBird.menuBarImage(tint: tint, meter: (level: $0, steps: CPUMeter.steps))
        }
    }

    var body: some Scene {
        MenuBarExtra {
            KilldeerMenu(monitor: monitor, loginItem: loginItem)
        } label: {
            // Colour is the warning signal, as DESIGN.md asks for: the bird
            // stays the bird and turns red. Swapping in a warning triangle
            // would put a second, unrelated shape in the menu bar for the state
            // that matters most, which is the worst moment to make someone
            // re-read the icon. The meter beside it is always there and only
            // ever changes how full it is.
            let icons = monitor.hasRunaways ? Self.warningIcons : Self.restingIcons
            Image(nsImage: icons[monitor.cpuMeterLevel])
                .accessibilityLabel(monitor.accessibilityLabel)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct KilldeerMenu: View {
    @ObservedObject var monitor: ProcessMonitor
    @ObservedObject var loginItem: LoginItemController

    var body: some View {
        Text(monitor.statusText)

        if !monitor.systemText.isEmpty {
            Text(monitor.systemText)
        }

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

        if !monitor.topProcesses.isEmpty {
            Divider()
            Text("Top Processes")
            // Every process, not only Chrome and not only runaways: this is
            // the answer to "what is using the CPU" before anything crosses
            // the runaway line. Kill sits one level down, as it does for the
            // Chrome instances, so reading the list cannot end a process.
            ForEach(monitor.topProcesses, id: \.process.identity) { finding in
                Menu("\(finding.process.name) — \(finding.cpuPercent, specifier: "%.1f")% CPU") {
                    Text("PID \(finding.process.identity.pid)")
                    if !finding.process.executablePath.isEmpty {
                        Text(finding.process.executablePath)
                    }
                    Button("Kill PID \(finding.process.identity.pid)") {
                        monitor.killProcess(finding)
                    }
                    .disabled(monitor.isWorking)
                }
            }
        }

        if !monitor.chromeInstances.isEmpty {
            Divider()
            Menu("Chrome Instances (\(monitor.chromeInstances.count))") {
                // A submenu per instance rather than a flat list: the summary
                // line is already long, and kill has to sit behind a second
                // press so a mis-click cannot take down a browser full of tabs.
                ForEach(monitor.chromeInstances, id: \.id) { instance in
                    Menu(instance.menuSummary) {
                        if let directory = instance.userDataDirectory {
                            Text(directory)
                        }
                        if let launchedBy = instance.launchedBy {
                            Text("Launched by \(launchedBy)")
                        }
                        if instance.isOrphaned {
                            // One button per stray: the row groups helpers that
                            // have nothing to do with each other beyond having
                            // lost the same kind of browser.
                            ForEach(instance.helpers, id: \.identity) { helper in
                                Button("Kill PID \(helper.identity.pid) — \(helper.role.displayName)") {
                                    monitor.killChromeProcess(helper)
                                }
                                .disabled(monitor.isWorking)
                            }
                        } else {
                            Button("Kill \(instance.displayName)") {
                                monitor.killChromeInstance(instance)
                            }
                            .disabled(monitor.isWorking)
                        }
                    }
                }
            }
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

        Button("Activity Monitor") {
            monitor.openActivityMonitor()
        }

        Button("Settings…") {
            monitor.showSettingsPlaceholder()
        }

        // Killdeer's menu has no About item to sit under, so this goes with
        // the other app-level entries just above Quit.
        Button("Third-Party Licenses…") {
            LicenseWindow.show()
        }

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }
}

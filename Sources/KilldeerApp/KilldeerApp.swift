import AppKit
import KilldeerCore
import SwiftUI

@main
struct KilldeerApp: App {
    @StateObject private var monitor: ProcessMonitor
    @StateObject private var loginItem = LoginItemController()
    @StateObject private var settings: MeterSettings
    @StateObject private var flap: FlapClock

    // The pictures already drawn, by what they show. The label is rebuilt on
    // every published change from the monitor, and rasterising the glyph each
    // time would redraw it several times a minute; drawn from the quantised
    // level there are only a few dozen pictures a style can ever be.
    @MainActor private static let images = MeterImageCache()

    init() {
        // The clock follows the monitor and the settings, so the three are
        // made together; StateObject keeps the first set for the life of the
        // scene.
        let monitor = ProcessMonitor()
        let settings = MeterSettings()
        _monitor = StateObject(wrappedValue: monitor)
        _settings = StateObject(wrappedValue: settings)
        _flap = StateObject(wrappedValue: FlapClock(monitor: monitor, settings: settings))
    }

    var body: some Scene {
        MenuBarExtra {
            KilldeerMenu(monitor: monitor, loginItem: loginItem, settings: settings)
        } label: {
            // Colour is the warning signal, as DESIGN.md asks for: whatever
            // the style, the picture stays itself and turns red. Swapping in a
            // warning triangle would put a second, unrelated shape in the menu
            // bar for the state that matters most, which is the worst moment
            // to make someone re-read the icon. The load is the picture's
            // shape, and only ever changes how full it is.
            let frame = MeterFrame(
                style: settings.style,
                level: monitor.cpuMeterLevel,
                coreLevels: settings.style.usesCores ? monitor.coreLevels : [],
                flapFrame: settings.style.isAnimated ? flap.frame : 0,
                warning: monitor.hasRunaways
            )
            Image(nsImage: Self.images.image(for: frame))
                .accessibilityLabel(monitor.accessibilityLabel)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct KilldeerMenu: View {
    @ObservedObject var monitor: ProcessMonitor
    @ObservedObject var loginItem: LoginItemController
    @ObservedObject var settings: MeterSettings

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

        // The style here as well as in the settings window: switching is the
        // one setting that is tried a few times before it settles, and the
        // menu is where the result is.
        Menu("Menu Bar Style") {
            ForEach(MeterStyle.allCases, id: \.self) { style in
                Button {
                    settings.style = style
                } label: {
                    Text("\(settings.style == style ? "✓" : "  ") \(style.displayName)")
                }
            }
        }

        Button("Settings…") {
            SettingsWindow.show(settings: settings, monitor: monitor)
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

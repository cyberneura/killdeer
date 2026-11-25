import AppKit
import KilldeerCore
import SwiftUI

@main
struct KilldeerApp: App {
    // Plain references, not StateObjects. An ObservableObject held by the App
    // invalidates the whole scene on every change, whichever property moved,
    // and the menu is rebuilt with it: a submenu left open closes on the next
    // reading. Each view observes only what it draws. The App is initialised
    // once, so these are made once.
    private let monitor: ProcessMonitor
    private let loginItem = LoginItemController()
    private let settings: MeterSettings
    private let flap: FlapClock
    private let menuContent: MenuContent

    init() {
        let monitor = ProcessMonitor()
        let settings = MeterSettings()
        self.monitor = monitor
        self.settings = settings
        flap = FlapClock(monitor: monitor, settings: settings)
        menuContent = MenuContent(monitor: monitor, settings: settings)
    }

    var body: some Scene {
        MenuBarExtra {
            KilldeerMenu(monitor: monitor, content: menuContent, loginItem: loginItem, settings: settings)
        } label: {
            MenuBarLabel(monitor: monitor, settings: settings, flap: flap)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var monitor: ProcessMonitor
    @ObservedObject var settings: MeterSettings
    @ObservedObject var flap: FlapClock

    // The pictures already drawn, by what they show. The label is rebuilt on
    // every published change from the monitor, several of which come with
    // each reading, and rasterising the glyph for each would redraw the same
    // picture several times over. See MeterImageCache for how many keys
    // each style makes.
    @MainActor private static let images = MeterImageCache()

    var body: some View {
        // Colour is the warning signal, as DESIGN.md asks for: whatever the
        // style, the picture stays itself and turns red. Swapping in a
        // warning triangle would put a second, unrelated shape in the menu
        // bar for the state that matters most, which is the worst moment to
        // make someone re-read the icon. The load is the picture's shape, and
        // only ever changes how full it is.
        let frame = MeterFrame(
            style: settings.style,
            monitor: monitor,
            settings: settings,
            flapFrame: settings.style.isAnimated ? flap.frame : 0,
            warning: monitor.isWarning
        )
        Image(nsImage: Self.images.image(for: frame))
            .accessibilityLabel(monitor.accessibilityLabel(
                order: settings.drawableOrder(temperatureAvailable: monitor.temperatureAvailable)
            ))
    }
}

private struct KilldeerMenu: View {
    /// For the actions only. What the menu shows comes from `content`, which
    /// holds still while the menu is open; observing the monitor here would
    /// rebuild the menu on every reading.
    let monitor: ProcessMonitor
    @ObservedObject var content: MenuContent
    @ObservedObject var loginItem: LoginItemController
    @ObservedObject var settings: MeterSettings

    var body: some View {
        Text(content.snapshot.statusText)

        // All of them, whatever the style has room for: the picture shows
        // the first one or two, and this is where the rest are.
        ForEach(content.snapshot.parameterLines, id: \.self) { line in
            Text(line)
        }

        if let strainText = content.snapshot.strainText {
            Text(strainText)
        }

        Button("Scan Now") {
            monitor.scanNow()
        }
        .disabled(content.snapshot.isScanning)

        if !content.snapshot.findings.isEmpty {
            Divider()
            ForEach(content.snapshot.findings, id: \.process.identity) { finding in
                Button {
                    monitor.toggleSelection(finding.process.identity)
                } label: {
                    let selected = content.snapshot.selected.contains(finding.process.identity)
                    Text("\(selected ? "✓" : "  ") \(finding.process.name) — PID \(finding.process.identity.pid), \(finding.cpuPercent, specifier: "%.1f")% CPU")
                }
            }

            Menu("Kill Selected…") {
                Button("Confirm Kill \(content.snapshot.selected.count) Process\(content.snapshot.selected.count == 1 ? "" : "es")") {
                    monitor.killSelected()
                }
            }
            .disabled(content.snapshot.selected.isEmpty || content.snapshot.isWorking)
        }

        if !content.snapshot.topProcesses.isEmpty {
            Divider()
            Text("Top Processes")
            // Every process, not only Chrome and not only runaways: this is
            // the answer to "what is using the CPU" before anything crosses
            // the runaway line. Kill sits one level down, as it does for the
            // Chrome instances, so reading the list cannot end a process.
            ForEach(content.snapshot.topProcesses, id: \.process.identity) { finding in
                Menu("\(finding.process.name) — \(finding.cpuPercent, specifier: "%.1f")% CPU") {
                    Text("PID \(finding.process.identity.pid)")
                    if !finding.process.executablePath.isEmpty {
                        Text(finding.process.executablePath)
                    }
                    Button("Kill PID \(finding.process.identity.pid)") {
                        monitor.killProcess(finding)
                    }
                    .disabled(content.snapshot.isWorking)
                }
            }
        }

        Divider()

        if !content.snapshot.chromeInstances.isEmpty {
            Menu("Chrome Instances (\(content.snapshot.chromeInstances.count))") {
                // A submenu per instance rather than a flat list: the summary
                // line is already long, and kill has to sit behind a second
                // press so a mis-click cannot take down a browser full of tabs.
                ForEach(content.snapshot.chromeInstances, id: \.id) { instance in
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
                                .disabled(content.snapshot.isWorking)
                            }
                        } else {
                            Button("Kill \(instance.displayName)") {
                                monitor.killChromeInstance(instance)
                            }
                            .disabled(content.snapshot.isWorking)
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
        .disabled(content.snapshot.isWorking)

        if !content.snapshot.agentInstances.isEmpty {
            Menu("AI Agents (\(content.snapshot.agentInstances.count))") {
                ForEach(content.snapshot.agentInstances, id: \.id) { instance in
                    AgentInstanceMenu(instance: instance, monitor: monitor, isWorking: content.snapshot.isWorking)
                }
            }
        }

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

/// One agent session: what it is and where, then its processes.
private struct AgentInstanceMenu: View {
    let instance: AgentInstance
    let monitor: ProcessMonitor
    let isWorking: Bool

    /// Rows listed before the rest are folded into a count. A session that
    /// started a browser has dozens of processes, and a submenu taller than
    /// the screen scrolls.
    private static let processLimit = 12

    var body: some View {
        Menu(instance.menuSummary) {
            if let directory = instance.workingDirectory {
                Text(directory)
            }
            Text(details)
            Divider()
            let listed = instance.listedProcesses(limit: Self.processLimit)
            // Kill sits one level down, as it does for Top Processes, so
            // reading the list cannot end a process. There is no button for
            // the whole session: ending the agent's own row does that, and
            // the agent decides what to do with what it started.
            ForEach(listed.shown, id: \.identity) { process in
                Menu(process.menuSummary) {
                    Text("PID \(process.identity.pid)")
                    if !process.snapshot.executablePath.isEmpty {
                        Text(process.snapshot.executablePath)
                    }
                    Button("Kill PID \(process.identity.pid)") {
                        monitor.killAgentProcess(process)
                    }
                    .disabled(isWorking)
                }
            }
            if listed.hidden > 0 {
                Text("+ \(listed.hidden) more")
            }
        }
    }

    private var details: String {
        var parts = ["PID \(instance.root.identity.pid)"]
        if let launchedBy = instance.launchedBy { parts.append("launched by \(launchedBy)") }
        parts.append("started \(ChromeFormatting.relativeTime(instance.startTime))")
        return parts.joined(separator: " — ")
    }
}

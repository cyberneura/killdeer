import AppKit
import KilldeerCore
import SwiftUI

/// The window behind the menu's Settings… item. Like the licenses window it
/// is an AppKit window the menu action opens, kept so that a second press
/// brings it forward rather than opening another, and holding a SwiftUI view
/// for the controls.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(settings: MeterSettings, monitor: ProcessMonitor) {
        let window = self.window ?? makeWindow(settings: settings, monitor: monitor)
        self.window = window
        // Killdeer is an LSUIElement app with no Dock icon; without activating
        // it the window opens behind whatever the user was working in.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private static func makeWindow(settings: MeterSettings, monitor: ProcessMonitor) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Killdeer Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(settings: settings, monitor: monitor))
        window.center()
        return window
    }
}

struct SettingsView: View {
    @ObservedObject var settings: MeterSettings
    @ObservedObject var monitor: ProcessMonitor

    var body: some View {
        Form {
            Section("Menu Bar") {
                // A list of rows rather than a Picker: each row carries the
                // style's own picture at the current reading, which a radio
                // group would reduce to its text.
                ForEach(MeterStyle.allCases, id: \.self) { style in
                    Button {
                        settings.style = style
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: settings.style == style ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(settings.style == style ? Color.accentColor : Color.secondary)
                            Image(nsImage: preview(style))
                                .frame(width: 48, alignment: .center)
                            Text(style.displayName)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Text(settings.style.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Polling") {
                Text("Killdeer reads the CPU and scans for processes every \(monitor.pollingInterval.formatted()) seconds. Start it with --interval, or set KILLDEER_INTERVAL, to change that.")
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }

    /// The style's picture at the machine's current reading, as the menu bar
    /// would show it now. Not from the cache: the previews are drawn for one
    /// open window, and the cache is sized for the one picture the status
    /// item shows.
    private func preview(_ style: MeterStyle) -> NSImage {
        MeterArt.image(for: MeterFrame(
            style: style,
            level: monitor.cpuMeterLevel,
            coreLevels: style.usesCores ? monitor.coreLevels : [],
            flapFrame: 0,
            warning: false
        ))
    }
}

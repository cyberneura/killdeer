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
        let content = NSHostingView(rootView: SettingsView(settings: settings, monitor: monitor))
        // As tall as the form, so that nothing is below a scroll that a
        // window with no visible scroller gives no hint of; on a screen too
        // short for that the form scrolls.
        let available = (NSScreen.main?.visibleFrame.height ?? 800) - 60
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: min(content.fittingSize.height, available)),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Killdeer Settings"
        window.isReleasedWhenClosed = false
        window.contentView = content
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
                Text("Showing: \(shownParameters)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Parameters") {
                // Buttons rather than drag and drop: four rows in a grouped
                // form give dragging nothing to hold on to, and a press on an
                // arrow says where the row went.
                ForEach(Array(settings.parameterOrder.enumerated()), id: \.element) { index, parameter in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(parameter.displayName)
                            Text(caption(for: parameter))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            move(parameter, by: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(index == 0)
                        .accessibilityLabel("Move \(parameter.displayName) up")
                        Button {
                            move(parameter, by: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(index == settings.parameterOrder.count - 1)
                        .accessibilityLabel("Move \(parameter.displayName) down")
                    }
                    // Borderless, or a press anywhere in a form row presses
                    // the row's first button.
                    .buttonStyle(.borderless)
                }
                Text("A style shows as many of these as it has room for, starting from the top. The menu always lists them all.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("History graph rows", selection: $settings.historyRows) {
                    ForEach(Array(HistoryGraph.rowChoices), id: \.self) { rows in
                        Text("\(rows)").tag(rows)
                    }
                }
                .pickerStyle(.segmented)
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
        MeterArt.image(for: MeterFrame(style: style, monitor: monitor, settings: settings, flapFrame: 0, warning: false))
    }

    /// Which parameter is in which part of the chosen style's picture.
    private var shownParameters: String {
        settings.slots(for: settings.style, temperatureAvailable: monitor.temperatureAvailable)
            .map { "\($0.parameter.displayName) (\($0.part))" }
            .joined(separator: ", ")
    }

    private func caption(for parameter: MeterParameter) -> String {
        if parameter == .temperature, !monitor.temperatureAvailable {
            return "No readable sensor on this Mac, so the styles skip it"
        }
        return parameter.summary
    }

    private func move(_ parameter: MeterParameter, by offset: Int) {
        settings.parameterOrder = MeterParameterOrder.moving(parameter, by: offset, in: settings.parameterOrder)
    }
}

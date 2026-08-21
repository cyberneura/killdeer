import AppKit
import SwiftUI

@main
struct KilldeerApp: App {
    @StateObject private var monitor = ProcessMonitor()

    var body: some Scene {
        MenuBarExtra {
            KilldeerMenu(monitor: monitor)
        } label: {
            Image(systemName: monitor.hasRunaways ? "exclamationmark.triangle.fill" : "bird.fill")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(monitor.hasRunaways ? Color.red : Color.primary)
                .accessibilityLabel(monitor.hasRunaways ? "Killdeer warning" : "Killdeer")
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct KilldeerMenu: View {
    @ObservedObject var monitor: ProcessMonitor

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

        Button("Settings…") {
            monitor.showSettingsPlaceholder()
        }

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }
}

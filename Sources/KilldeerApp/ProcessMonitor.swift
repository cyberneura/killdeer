import AppKit
import Foundation
import KilldeerCore
import UserNotifications

@MainActor
final class ProcessMonitor: ObservableObject {
    @Published private(set) var findings: [ProcessFinding] = []
    @Published private(set) var selected: Set<ProcessIdentity> = []
    @Published private(set) var isScanning = false
    @Published private(set) var isWorking = false
    @Published private(set) var lastError: String?
    /// Kept apart from `lastError`, which every poll resets. A process the user
    /// asked to kill and which is still running has to stay on screen until
    /// they do something about it, not until the next scan a few seconds later.
    @Published private(set) var terminationError: String?
    @Published private(set) var cpuPercent: Double?
    @Published private(set) var temperatureCelsius: Double?
    @Published private(set) var chromeInstances: [ChromeInstance] = []

    private let detector = ProcessDetector()
    private let chromeInspector = ChromeInspector()
    private let temperatureReader = TemperatureReader()
    private var previousCPUTicks: CPUTicks?
    private let pollingInterval: TimeInterval
    private var pollingTask: Task<Void, Never>?
    private var runningScan: Task<Void, Never>?
    private var knownRunawayPIDs: Set<pid_t> = []

    var hasRunaways: Bool { !findings.isEmpty }

    /// The system line under the status.
    ///
    /// A machine with no readable sensors still shows its CPU figure here, so
    /// the only time this is empty is the first poll, before there are two tick
    /// samples to subtract, on a machine that also has no sensors. The menu
    /// drops the row then rather than showing a pair of dashes.
    var systemText: String {
        var parts: [String] = []
        if let cpuPercent { parts.append(String(format: "CPU %.1f%%", cpuPercent)) }
        if let temperatureCelsius { parts.append(String(format: "%.1f °C", temperatureCelsius)) }
        return parts.joined(separator: "    ")
    }

    var statusText: String {
        if isScanning { return "Scanning…" }
        if isWorking { return "Terminating processes…" }
        if let terminationError { return "Kill failed: \(terminationError)" }
        if let lastError { return "Error: \(lastError)" }
        if findings.isEmpty { return "Idle — no runaway processes" }
        return "\(findings.count) runaway process\(findings.count == 1 ? "" : "es") detected"
    }

    init() {
        pollingInterval = Self.configuredPollingInterval()
        requestNotificationPermission()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshSystemStats()
            await self.scan()
            while !Task.isCancelled {
                let delay = UInt64(self.pollingInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { break }
                // Ahead of scan, and outside it: scan returns early while a
                // termination is in flight, and the figures should keep moving
                // through exactly that.
                await self.refreshSystemStats()
                await self.scan()
            }
        }
    }

    deinit {
        pollingTask?.cancel()
    }

    func scanNow() {
        terminationError = nil
        Task { await scan() }
    }

    func toggleSelection(_ identity: ProcessIdentity) {
        if selected.contains(identity) {
            selected.remove(identity)
        } else {
            selected.insert(identity)
        }
    }

    func killSelected() {
        let targets = findings.filter { selected.contains($0.process.identity) }
        terminate(targets)
    }

    func cleanOrphanChrome() {
        guard !isWorking else { return }
        isWorking = true
        lastError = nil
        terminationError = nil
        Task {
            var failure: String?
            do {
                let orphans = try await Task.detached { [detector] in
                    try detector.sample().filter(\.isOrphanChromeHelper)
                }.value
                try await terminateInBackground(orphans)
            } catch {
                failure = error.localizedDescription
            }
            // Cleared before the refresh, not after: scan returns early while a
            // termination is in flight, so scanning first would leave the menu
            // listing what was just killed until the next poll — long enough to
            // press it again and be told the process no longer exists.
            isWorking = false
            await refresh(reporting: failure)
        }
    }

    /// Signals only the browser process. Chrome shuts its own helpers down on
    /// exit, and killing them first makes it report a crash on next launch.
    ///
    /// Takes no orphan row: those group unrelated strays under one heading, so
    /// there is no single process that stands for the row. The menu offers
    /// those one at a time through `killChromeProcess` instead.
    func killChromeInstance(_ instance: ChromeInstance) {
        guard let browser = instance.browser else { return }
        killChromeProcess(browser)
    }

    func killChromeProcess(_ process: ChromeProcess) {
        terminate([ProcessFinding(
            process: process.snapshot,
            cpuPercent: process.cpuPercent,
            isOrphanChromeHelper: false,
            score: 0,
            reasons: []
        )])
    }

    func openActivityMonitor() {
        // Resolved by bundle identifier rather than by path. The path has moved
        // between macOS versions, and Launch Services knows where it is now.
        guard let url = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor")
        else {
            lastError = "Activity Monitor could not be found"
            return
        }
        // The launch itself fails asynchronously. Without the handler a press
        // that goes nowhere looks exactly like one that worked.
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) {
            [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.lastError = error.localizedDescription }
        }
    }

    private func refreshSystemStats() async {
        let reader = temperatureReader
        let sample = await Task.detached {
            (ticks: CPULoad.sample(), readings: reader.readings())
        }.value

        if let ticks = sample.ticks {
            // The first sample has nothing to subtract from, so the percentage
            // appears one poll later rather than reading 0% at launch.
            if let previous = previousCPUTicks {
                cpuPercent = CPULoad.percentage(from: previous, to: ticks)
            }
            previousCPUTicks = ticks
        }
        temperatureCelsius = TemperatureSelection.representative(from: sample.readings)
    }

    func showSettingsPlaceholder() {
        let alert = NSAlert()
        alert.messageText = "Killdeer Settings"
        alert.informativeText = "Threshold and exclusion settings are planned for a future release. The polling interval is currently \(pollingInterval.formatted()) seconds."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func refresh(reporting failure: String?) async {
        await scan()
        terminationError = failure
    }

    /// Scans are serialised rather than skipped.
    ///
    /// A periodic scan that took its snapshots before a kill is about to
    /// publish what was just terminated. Turning the post-kill refresh away
    /// because that one is still running would leave the menu offering a
    /// process that no longer exists until the next poll.
    private func scan() async {
        if let running = runningScan { await running.value }
        guard !isWorking else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performScan()
        }
        runningScan = task
        await task.value
        if runningScan == task { runningScan = nil }
    }

    private func performScan() async {
        isScanning = true
        lastError = nil
        do {
            // One sample feeds both views. Sampling twice would double the
            // one-second measurement window on every poll.
            let result = try await Task.detached { [detector, chromeInspector] in
                let all = try detector.sample()
                return (runaways: all.filter(\.isRunaway), chrome: chromeInspector.instances(from: all))
            }.value
            chromeInstances = result.chrome
            let sampled = result.runaways
            let currentPIDs = Set(sampled.map { $0.process.identity.pid })
            let newPIDs = currentPIDs.subtracting(knownRunawayPIDs)
            findings = sampled
            selected.formIntersection(Set(sampled.map(\.process.identity)))
            knownRunawayPIDs = currentPIDs
            if !newPIDs.isEmpty { postNotification(count: newPIDs.count) }
        } catch {
            lastError = error.localizedDescription
        }
        isScanning = false
    }

    private func terminate(_ targets: [ProcessFinding]) {
        guard !targets.isEmpty, !isWorking else { return }
        isWorking = true
        lastError = nil
        terminationError = nil
        Task {
            var failure: String?
            do {
                try await terminateInBackground(targets)
                selected.removeAll()
            } catch {
                failure = error.localizedDescription
            }
            // See cleanOrphanChrome: the refresh has to happen with isWorking
            // already cleared. A failure is refreshed too, since the usual
            // reason to fail is that the process went away on its own.
            isWorking = false
            await refresh(reporting: failure)
        }
    }

    private func terminateInBackground(_ targets: [ProcessFinding]) async throws {
        try await Task.detached {
            let terminator = ProcessTerminator()
            for finding in targets {
                try terminator.terminate(finding.process.identity)
            }
        }.value
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postNotification(count: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Killdeer detected a runaway process"
        content.body = "\(count) new runaway process\(count == 1 ? "" : "es") detected. Open Killdeer to review."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private static func configuredPollingInterval() -> TimeInterval {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--interval"), arguments.indices.contains(index + 1),
           let value = TimeInterval(arguments[index + 1]), value > 0 {
            return value
        }
        if let raw = ProcessInfo.processInfo.environment["KILLDEER_INTERVAL"],
           let value = TimeInterval(raw), value > 0 {
            return value
        }
        return 10
    }
}

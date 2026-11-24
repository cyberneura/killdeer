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
    /// The use of each core, in core order. Starts as one idle reading per
    /// core rather than empty, so that the per-core styles are drawn at their
    /// full width from launch instead of growing with the first sample.
    @Published private(set) var corePercents: [Double] =
        Array(repeating: 0, count: ProcessInfo.processInfo.activeProcessorCount)
    @Published private(set) var temperatureCelsius: Double?
    @Published private(set) var history = LoadHistory()
    /// Trouble with the whole machine rather than with one process.
    @Published private(set) var strain = SystemStrain()
    @Published private(set) var chromeInstances: [ChromeInstance] = []
    /// The busiest processes of the last scan, runaway or not.
    @Published private(set) var topProcesses: [ProcessFinding] = []

    private let detector = ProcessDetector()
    private let chromeInspector = ChromeInspector()
    private let temperatureReader = TemperatureReader()
    private var previousCPUTicks: CPUTicks?
    private var previousCoreTicks: [CPUTicks]?
    private var peggedCPU = PeggedCPUDetector()
    /// `ProcessInfo.systemUptime` at the sample `previousCPUTicks` came from.
    private var previousCPUSampleUptime: TimeInterval?
    private var thermalObserver: NSObjectProtocol?
    let pollingInterval: TimeInterval
    private var pollingTask: Task<Void, Never>?
    private var runningScan: Task<Void, Never>?
    private var knownRunawayPIDs: Set<pid_t> = []

    var hasRunaways: Bool { !findings.isEmpty }

    /// What turns the menu bar picture red.
    var isWarning: Bool { hasRunaways || strain.isWarning }

    /// How full the meter beside the menu bar bird is, from 0 to
    /// `CPUMeter.steps`.
    var cpuMeterLevel: Int { CPUMeter.level(forPercent: cpuPercent) }

    /// One level per bar or tile for the per-core styles.
    var coreLevels: [Int] { CoreMeter.levels(forPercents: corePercents) }

    /// Spoken for the menu bar item. The meter is drawn, so without the figure
    /// here VoiceOver would announce the bird and nothing of what it shows.
    var accessibilityLabel: String {
        var label = isWarning ? "Killdeer warning" : "Killdeer"
        if let cpuPercent { label += String(format: ", CPU %.0f%%", cpuPercent) }
        if let temperatureCelsius { label += String(format: ", %.0f degrees Celsius", temperatureCelsius) }
        return label
    }

    /// The system line under the status, worded for `style`.
    ///
    /// A machine with no readable sensors still shows its CPU figure here, so
    /// the only time this is empty is the first poll, before there are two tick
    /// samples to subtract, on a machine that also has no sensors. The menu
    /// drops the row then rather than showing a pair of dashes.
    func systemText(style: MeterStyle) -> String {
        SystemLine.text(cpuPercent: cpuPercent, temperatureCelsius: temperatureCelsius, style: style)
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
        // Told rather than polled: a state that came and went between two
        // polls would otherwise never be seen.
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateStrain() }
        }
        updateStrain()
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
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
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

    func killProcess(_ finding: ProcessFinding) {
        terminate([finding])
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
            (ticks: CPULoad.sample(), uptime: ProcessInfo.processInfo.systemUptime,
             cores: CPULoad.sampleCores(), readings: reader.readings())
        }.value

        // This poll's own figure for the history. cpuPercent keeps the last
        // good one when a sample fails, which suits the menu but would put a
        // reading into the graph that was never taken.
        var polledCPUPercent: Double?
        if let ticks = sample.ticks {
            // The first sample has nothing to subtract from, so the percentage
            // appears one poll later rather than reading 0% at launch.
            if let previous = previousCPUTicks {
                cpuPercent = CPULoad.percentage(from: previous, to: ticks)
                polledCPUPercent = cpuPercent
            }
            previousCPUTicks = ticks
        }
        // A failed sample leaves the previous ticks in place, so the next
        // figure covers the time since those, and so does this.
        let elapsed = previousCPUSampleUptime.map { sample.uptime - $0 } ?? 0
        if sample.ticks != nil { previousCPUSampleUptime = sample.uptime }
        if let cores = sample.cores {
            if let previous = previousCoreTicks,
               let percents = CPULoad.corePercentages(from: previous, to: cores) {
                corePercents = percents
            }
            previousCoreTicks = cores
        }
        temperatureCelsius = TemperatureSelection.representative(from: sample.readings)
        history.append(cpuPercent: polledCPUPercent, temperatureCelsius: temperatureCelsius)

        _ = peggedCPU.update(cpuPercent: polledCPUPercent, interval: elapsed)
        updateStrain()
    }

    private func updateStrain() {
        let current = SystemStrain(
            cpuPegged: peggedCPU.isPegged,
            thermal: ThermalPressure(ProcessInfo.processInfo.thermalState)
        )
        guard current != strain else { return }
        let announcements = current.notifications(since: strain)
        strain = current
        for announcement in announcements {
            postNotification(title: announcement.title, body: announcement.body)
        }
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
            // One sample feeds every view. Sampling again would add another
            // one-second measurement window to every poll.
            let result = try await Task.detached { [detector, chromeInspector] in
                let all = try detector.sample()
                return (
                    runaways: all.filter(\.isRunaway),
                    top: TopProcesses.select(from: all),
                    chrome: chromeInspector.instances(from: all)
                )
            }.value
            chromeInstances = result.chrome
            topProcesses = result.top
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

    /// UNUserNotificationCenter raises an uncaught exception when the process
    /// is not inside an .app, which is how `swift run killdeer-app` starts it.
    /// The Info.plist linked into the executable gives it a bundle identifier
    /// but not a bundle, so the identifier is no test.
    private static let canNotify = Bundle.main.bundleURL.pathExtension == "app"

    private func requestNotificationPermission() {
        guard Self.canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postNotification(count: Int) {
        postNotification(
            title: "Killdeer detected a runaway process",
            body: "\(count) new runaway process\(count == 1 ? "" : "es") detected. Open Killdeer to review."
        )
    }

    private func postNotification(title: String, body: String) {
        guard Self.canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private static func configuredPollingInterval() -> TimeInterval {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--interval"), arguments.indices.contains(index + 1),
           let value = usableInterval(arguments[index + 1]) {
            return value
        }
        if let raw = ProcessInfo.processInfo.environment["KILLDEER_INTERVAL"],
           let value = usableInterval(raw) {
            return value
        }
        return 10
    }

    /// At most a day. The sleep converts the interval to nanoseconds in a
    /// UInt64, which traps for infinity and for anything past about 584 years.
    private static func usableInterval(_ raw: String) -> TimeInterval? {
        guard let value = TimeInterval(raw), value.isFinite, value > 0, value <= 86_400 else { return nil }
        return value
    }
}

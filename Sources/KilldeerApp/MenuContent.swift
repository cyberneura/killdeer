import AppKit
import Combine
import KilldeerCore

/// What the pull-down menu shows, held still while the menu is open.
///
/// A scan that adds or drops a row (the Top Processes section appearing, a
/// runaway turning up) moves every item below it, and AppKit closes whatever
/// submenu was open over the moved items. So while the menu is tracked the
/// rows stay as they were when it opened, and the latest state is applied
/// when it closes. The menu bar picture does not read from here and keeps
/// moving.
@MainActor
final class MenuContent: ObservableObject {
    struct Snapshot {
        var statusText = ""
        /// One line per parameter, in the user's order.
        var parameterLines: [String] = []
        var strainText: String?
        var isScanning = false
        var isWorking = false
        var findings: [ProcessFinding] = []
        var selected: Set<ProcessIdentity> = []
        var topProcesses: [ProcessFinding] = []
        var chromeInstances: [ChromeInstance] = []
        var agentInstances: [AgentInstance] = []
    }

    @Published private(set) var snapshot = Snapshot()

    private let monitor: ProcessMonitor
    private let settings: MeterSettings
    private var subscriptions: Set<AnyCancellable> = []
    /// The status item's menu posts one begin and one end per opening, not
    /// one per submenu. A count rather than a flag because the notifications
    /// are app-wide rather than tied to this menu, and a count stays right if
    /// another menu's tracking ever overlaps it.
    private var openMenus = 0

    init(monitor: ProcessMonitor, settings: MeterSettings) {
        self.monitor = monitor
        self.settings = settings
        refresh()
        // objectWillChange fires before the new value is stored, hence the hop
        // to the next turn of the run loop before reading it.
        monitor.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        // The parameter lines follow the order and name the style's parts.
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
            .sink { [weak self] _ in self?.openMenus += 1 }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                openMenus = max(0, openMenus - 1)
                refresh()
            }
            .store(in: &subscriptions)
    }

    private func refresh() {
        guard openMenus == 0 else { return }
        snapshot = Snapshot(
            statusText: monitor.statusText,
            parameterLines: ParameterLine.lines(
                order: settings.drawableOrder(temperatureAvailable: monitor.temperatureAvailable),
                slots: settings.slots(for: settings.style, temperatureAvailable: monitor.temperatureAvailable),
                readings: monitor.readings
            ),
            strainText: monitor.strain.menuText,
            isScanning: monitor.isScanning,
            isWorking: monitor.isWorking,
            findings: monitor.findings,
            selected: monitor.selected,
            topProcesses: monitor.topProcesses,
            chromeInstances: monitor.chromeInstances,
            agentInstances: monitor.agentInstances
        )
    }
}

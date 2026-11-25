import Combine
import Foundation
import KilldeerCore

/// The settings that shape the menu bar item, kept in the user defaults so
/// that they survive a relaunch. The menu and the settings window both bind
/// to this one object; the status item follows it through the app's body.
@MainActor
final class MeterSettings: ObservableObject {
    @Published var style: MeterStyle {
        didSet { defaults.set(style.rawValue, forKey: MeterStyle.defaultsKey) }
    }

    /// Every parameter, the one a style should show first at the front.
    @Published var parameterOrder: [MeterParameter] {
        didSet { defaults.set(parameterOrder.map(\.rawValue), forKey: MeterParameterOrder.defaultsKey) }
    }

    /// How many rows the history graph has.
    @Published var historyRows: Int {
        didSet { defaults.set(historyRows, forKey: HistoryGraph.rowsDefaultsKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A value from a build that no longer knows the style falls back to
        // the default rather than leaving the item blank.
        style = defaults.string(forKey: MeterStyle.defaultsKey)
            .flatMap(MeterStyle.init(rawValue:)) ?? .default
        parameterOrder = MeterParameterOrder.parse(defaults.stringArray(forKey: MeterParameterOrder.defaultsKey))
        historyRows = (defaults.object(forKey: HistoryGraph.rowsDefaultsKey) as? Int)
            .map(HistoryGraph.clampedRows) ?? HistoryGraph.defaultRows
    }

    /// The order with the temperature left out on a Mac that has no sensor:
    /// what the styles draw from and the menu lists.
    func drawableOrder(temperatureAvailable: Bool) -> [MeterParameter] {
        MeterParameterOrder.drawable(parameterOrder, temperatureAvailable: temperatureAvailable)
    }

    func slots(for style: MeterStyle, temperatureAvailable: Bool) -> [MeterSlot] {
        style.slots(order: drawableOrder(temperatureAvailable: temperatureAvailable), historyRows: historyRows)
    }
}

extension MeterFrame {
    /// The picture of `style` at the monitor's current readings, with the
    /// parameters placed by the settings' order. The status item and the
    /// settings window's previews are both built here, so that a preview
    /// cannot show something the menu bar would not.
    @MainActor
    init(style: MeterStyle, monitor: ProcessMonitor, settings: MeterSettings, flapFrame: Int, warning: Bool) {
        self.init(
            style: style,
            levels: MeterLevels(
                style: style,
                slots: settings.slots(for: style, temperatureAvailable: monitor.temperatureAvailable),
                readings: monitor.readings,
                history: monitor.history
            ),
            coreLevels: style.usesCores ? monitor.coreLevels : [],
            flapFrame: flapFrame,
            warning: warning
        )
    }
}

/// The clock behind the flapping bird: which beat of the wing to draw.
///
/// Runs only while that style is chosen and its parameter is off the bottom
/// of the scale, at the rate `FlapRate` gives for the level; otherwise there
/// is no timer at all,
/// and the frame rests at zero. Follows the monitor and the settings through
/// Combine rather than being poked from the view, so that choosing a style
/// or a reading arriving cannot leave a timer running at the wrong rate.
@MainActor
final class FlapClock: ObservableObject {
    @Published private(set) var frame = 0

    private var timer: Timer?
    private var subscription: AnyCancellable?

    init(monitor: ProcessMonitor, settings: MeterSettings) {
        let temperatureAvailable = monitor.temperatureAvailable
        subscription = monitor.$readings
            .combineLatest(settings.$style, settings.$parameterOrder)
            .map { readings, style, order -> TimeInterval? in
                guard style.isAnimated else { return nil }
                let drawable = MeterParameterOrder.drawable(order, temperatureAvailable: temperatureAvailable)
                let level = style.slots(order: drawable).first.flatMap { readings.level(of: $0.parameter) }
                return FlapRate.interval(forLevel: level ?? 0)
            }
            .removeDuplicates()
            .sink { [weak self] interval in
                self?.schedule(every: interval)
            }
    }

    private func schedule(every interval: TimeInterval?) {
        timer?.invalidate()
        timer = nil
        guard let interval else {
            frame = 0
            return
        }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
        // Common modes, so the wing keeps beating while the menu is open:
        // menu tracking leaves the default mode.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func advance() {
        frame = (frame + 1) % FlapRate.frames
    }
}

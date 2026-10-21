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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A value from a build that no longer knows the style falls back to
        // the default rather than leaving the item blank.
        style = defaults.string(forKey: MeterStyle.defaultsKey)
            .flatMap(MeterStyle.init(rawValue:)) ?? .default
    }
}

/// The clock behind the flapping bird: which beat of the wing to draw.
///
/// Runs only while that style is chosen and the machine is not idle, at the
/// rate `FlapRate` gives for the level; otherwise there is no timer at all,
/// and the frame rests at zero. Follows the monitor and the settings through
/// Combine rather than being poked from the view, so that choosing a style
/// or a reading arriving cannot leave a timer running at the wrong rate.
@MainActor
final class FlapClock: ObservableObject {
    @Published private(set) var frame = 0

    private var timer: Timer?
    private var subscription: AnyCancellable?

    init(monitor: ProcessMonitor, settings: MeterSettings) {
        subscription = monitor.$cpuPercent
            .combineLatest(settings.$style)
            .map { percent, style -> TimeInterval? in
                guard style.isAnimated else { return nil }
                return FlapRate.interval(forLevel: CPUMeter.level(forPercent: percent))
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

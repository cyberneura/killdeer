import Foundation

/// How the menu bar item shows the CPU load. Chosen from the menu or the
/// settings window, and kept in the user defaults under `defaultsKey`.
///
/// Every style is drawn from the same quantised level, `CPUMeter.level`, so
/// that the image can only ever be one of a small number of pictures; the two
/// per-core styles add one level per core on top of that, three styles add the
/// temperature on `TemperatureMeter`'s ten steps, and the history graph draws
/// past readings on its own scale. The drawing lives
/// in the app, where AppKit is; what is here is the choice and the arithmetic
/// behind each picture, which is what can be tested without a screen.
public enum MeterStyle: String, CaseIterable, Sendable {
    /// The bird with the upright gauge beside it, as the app first shipped.
    case birdWithGauge = "bird-with-gauge"
    /// Two concentric rings filling clockwise from seven o'clock round to
    /// five: the CPU outside, the temperature inside.
    case ringGauge = "ring-gauge"
    /// The bird on its own, beating its wing faster the busier the machine is.
    case flappingBird = "flapping-bird"
    /// One upright bar per core, side by side like an equaliser.
    case coreBars = "core-bars"
    /// One tile per core, the darker the busier, with a temperature meter.
    case coreHeatmap = "core-heatmap"
    /// New moon at idle, waxing to a full moon at full load.
    case moonPhase = "moon-phase"
    /// Sun, then cloud, rain and thunder as the load climbs.
    case weather = "weather"
    /// A cup that fills with the load and spills over at full load, steaming
    /// with the temperature.
    case coffeeCup = "coffee-cup"
    /// The last few minutes of CPU use and temperature, as a small chart.
    case historyGraph = "history-graph"

    public static let `default` = MeterStyle.birdWithGauge

    /// The key the choice is stored under in the user defaults.
    public static let defaultsKey = "meterStyle"

    /// What the menu and the settings window call the style.
    public var displayName: String {
        switch self {
        case .birdWithGauge: return "Bird and gauge"
        case .ringGauge: return "Ring gauge"
        case .flappingBird: return "Flapping bird"
        case .coreBars: return "Core bars"
        case .coreHeatmap: return "Core heatmap"
        case .moonPhase: return "Moon phase"
        case .weather: return "Weather"
        case .coffeeCup: return "Coffee cup"
        case .historyGraph: return "History graph"
        }
    }

    /// One line on how to read the style, for the settings window.
    public var summary: String {
        switch self {
        case .birdWithGauge:
            return "The bird, with a gauge beside it that fills from the bottom in steps of ten percent."
        case .ringGauge:
            return "Two rings that fill clockwise from seven o'clock round to five, like a speedometer: the CPU use outside, the temperature inside."
        case .flappingBird:
            return "The bird alone. It sits still when the machine is idle and beats its wing faster as the load climbs."
        case .coreBars:
            return "One bar per core, so a single core pegged by one process stands out from an evenly busy machine."
        case .coreHeatmap:
            return "One tile per core, darker the busier the core, with a thin temperature meter at the right-hand edge."
        case .moonPhase:
            return "A new moon when idle, waxing through a half moon to a full moon at full load."
        case .weather:
            return "Sun when idle, then a cloud, rain, and thunder at full load."
        case .coffeeCup:
            return "A cup that fills with the load and spills over at full load; the hotter the chip, the more it steams."
        case .historyGraph:
            return "Two charts of the last \(LoadHistory.capacity) readings, newest at the right: the CPU use on top, and the temperature below, from \(Int(TemperatureMeter.range.lowerBound)) to \(Int(TemperatureMeter.range.upperBound)) °C."
        }
    }

    /// Whether the picture moves on its own, and so needs a clock behind it.
    public var isAnimated: Bool { self == .flappingBird }

    /// Whether the picture is drawn from the load of each core rather than
    /// from the one figure for the whole machine.
    public var usesCores: Bool { self == .coreBars || self == .coreHeatmap }

    /// Whether the picture is drawn from the past readings rather than the
    /// current one.
    public var usesHistory: Bool { self == .historyGraph }

    /// Whether the picture shows the current temperature beside the load.
    /// The history graph shows past temperatures instead, through
    /// `usesHistory`.
    public var usesTemperature: Bool {
        self == .ringGauge || self == .coffeeCup || self == .coreHeatmap
    }
}

/// The temperature on the same ten steps as `CPUMeter`, for the styles that
/// show it beside the load.
public enum TemperatureMeter {
    /// An idle Apple silicon die sits near 40 °C and a loaded one passes
    /// 100 °C, where it throttles; a scale starting at zero would spend a
    /// third of a small picture on temperatures a running chip never has.
    public static let range: ClosedRange<Double> = 30...100

    /// 0 through `steps`, or nil without a reading, so that "no sensor" can
    /// be told from "cool".
    public static func level(forCelsius celsius: Double?, steps: Int = CPUMeter.steps) -> Int? {
        guard let celsius, celsius.isFinite else { return nil }
        let position = (celsius - range.lowerBound) / (range.upperBound - range.lowerBound)
        return Int((min(max(position, 0), 1) * Double(steps)).rounded())
    }
}

/// The system line in the menu.
public enum SystemLine {
    /// The history graph's line says which row is which, since 18pt leaves
    /// no room to label the picture itself.
    public static func text(cpuPercent: Double?, temperatureCelsius: Double?, style: MeterStyle) -> String {
        var parts: [String] = []
        if style.usesHistory {
            if let cpuPercent { parts.append(String(format: "CPU %.0f%% (↑)", cpuPercent)) }
            if let temperatureCelsius { parts.append(String(format: "%.0f℃ (↓)", temperatureCelsius)) }
        } else {
            if let cpuPercent { parts.append(String(format: "CPU %.1f%%", cpuPercent)) }
            if let temperatureCelsius { parts.append(String(format: "%.1f °C", temperatureCelsius)) }
        }
        return parts.joined(separator: "    ")
    }
}

/// The readings of the last few polls, oldest first, for the history graph.
///
/// Kept whatever the style, so that switching to the graph shows the minutes
/// already gone rather than an empty chart that fills over the next five.
public struct LoadHistory: Equatable, Sendable {
    /// Readings kept: five minutes at the default ten-second poll, one point
    /// of the graph's width each.
    public static let capacity = 30

    /// nil where there was no reading: the first poll, before two tick samples
    /// exist, and every poll on a machine with no readable sensor.
    public private(set) var cpuPercents: [Double?] = []
    public private(set) var temperatures: [Double?] = []

    public init() {}

    public mutating func append(cpuPercent: Double?, temperatureCelsius: Double?) {
        cpuPercents.append(cpuPercent)
        temperatures.append(temperatureCelsius)
        if cpuPercents.count > Self.capacity {
            cpuPercents.removeFirst(cpuPercents.count - Self.capacity)
            temperatures.removeFirst(temperatures.count - Self.capacity)
        }
    }
}

/// The history graph's scales: how high each reading stands in the chart.
public enum HistoryGraph {
    /// Points of height each of the two rows has, one per step, so that a
    /// step is the finest change the menu bar can show anyway: 18pt holds two
    /// rows of 7 with a gap between them.
    public static let steps = 7

    /// One level per reading, padded at the front with nils to `capacity`, so
    /// that the newest is always at the right edge and the picture does not
    /// change width as the history fills.
    public static func cpuLevels(_ history: LoadHistory) -> [Int?] {
        padded(history.cpuPercents.map { $0.map(cpuLevel(forPercent:)) })
    }

    public static func temperatureLevels(_ history: LoadHistory) -> [Int?] {
        padded(history.temperatures.map { $0.flatMap(temperatureLevel(forCelsius:)) })
    }

    /// Like `CPUMeter.level`, anything above zero stands at least one step:
    /// a flat line along the bottom beside a non-zero figure would read as
    /// the graph being broken.
    static func cpuLevel(forPercent percent: Double) -> Int {
        guard percent.isFinite, percent > 0 else { return 0 }
        let filled = Int((min(percent, 100) / 100 * Double(steps)).rounded())
        return min(steps, max(1, filled))
    }

    /// nil for a reading that is no number, so that the line breaks rather
    /// than dropping to the floor.
    static func temperatureLevel(forCelsius celsius: Double) -> Int? {
        TemperatureMeter.level(forCelsius: celsius, steps: steps)
    }

    private static func padded(_ levels: [Int?]) -> [Int?] {
        let kept = levels.suffix(LoadHistory.capacity)
        return Array(repeating: nil, count: LoadHistory.capacity - kept.count) + kept
    }
}

/// The wing beat of the flapping bird.
public enum FlapRate {
    /// Pictures in one beat: wing up, halfway, down, halfway.
    public static let frames = 4

    /// Seconds between two pictures at `level` of `CPUMeter.steps`, or nil to
    /// keep the bird still. The beat quickens with the level, and is held to
    /// a dozen pictures a second at most: an app that watches the CPU should
    /// not be seen using it, and the status item is redrawn on every picture.
    public static func interval(forLevel level: Int) -> TimeInterval? {
        guard level > 0 else { return nil }
        return max(0.08, 0.8 / Double(min(level, CPUMeter.steps)))
    }
}

/// The picture the weather style draws.
public enum WeatherKind: CaseIterable, Sendable {
    case sun
    case sunBehindCloud
    case cloud
    case rain
    case thunder

    /// The weather for `level` of `CPUMeter.steps`: clear at the bottom, a
    /// storm at the top, with the steps shared out so that each picture
    /// covers about two of them.
    public static func forLevel(_ level: Int) -> WeatherKind {
        switch level {
        case ...1: return .sun
        case 2...3: return .sunBehindCloud
        case 4...5: return .cloud
        case 6...8: return .rain
        default: return .thunder
        }
    }
}

/// What the coffee cup style draws for a level.
public struct CoffeeCup: Equatable, Sendable {
    /// Wisps of steam above the cup, none to three.
    public let steamLines: Int
    /// Spilling over the rim, at full load only.
    public let overflowing: Bool

    /// `temperatureLevel` is on `TemperatureMeter`'s scale and sets the steam.
    /// Without one the steam follows the load, so that a Mac with no readable
    /// sensor still has a cup that steams.
    public static func forLevel(_ level: Int, temperatureLevel: Int? = nil) -> CoffeeCup {
        let level = CPUMeter.clamp(level)
        let steam: Int
        switch CPUMeter.clamp(temperatureLevel ?? level) {
        case 0: steam = 0
        case 1...3: steam = 1
        case 4...6: steam = 2
        default: steam = 3
        }
        return CoffeeCup(steamLines: steam, overflowing: level >= CPUMeter.steps)
    }

    /// How full the cup is, 0 to 1.
    public static func fill(forLevel level: Int) -> Double {
        Double(CPUMeter.clamp(level)) / Double(CPUMeter.steps)
    }
}

/// Where the moon's terminator falls for a level.
public enum MoonPhase {
    /// The half-width of the terminator's ellipse as a fraction of the moon's
    /// radius, signed: 1 at a new moon, where it lies on the lit limb and the
    /// lit part has no area, 0 at a half moon, and -1 at a full moon, where it
    /// lies on the far limb.
    public static func terminator(forLevel level: Int) -> Double {
        cos(.pi * Double(CPUMeter.clamp(level)) / Double(CPUMeter.steps))
    }
}

/// The arc of the ring gauge, as clock angles: degrees clockwise from twelve.
/// Both rings, the CPU outside and the temperature inside, share it.
public enum RingGauge {
    /// Seven o'clock.
    public static let startDegrees: Double = 210
    /// Round to five o'clock.
    public static let sweepDegrees: Double = 300

    /// How much of the sweep is filled at `level` of `CPUMeter.steps`.
    public static func sweep(forLevel level: Int) -> Double {
        sweepDegrees * Double(CPUMeter.clamp(level)) / Double(CPUMeter.steps)
    }
}

/// The per-core styles' reading of the cores.
public enum CoreMeter {
    /// Bars drawn at most. A machine with more cores than this has them
    /// averaged in groups, so that the status item does not run to half the
    /// menu bar.
    public static let maxBars = 16

    /// One level per bar, in core order. Cores beyond `maxBars` are averaged
    /// in equal groups of neighbours; a group with no finite reading draws
    /// empty.
    public static func levels(forPercents percents: [Double], maxBars: Int = maxBars) -> [Int] {
        guard !percents.isEmpty, maxBars > 0 else { return [] }
        let groupSize = Int((Double(percents.count) / Double(maxBars)).rounded(.up))
        return stride(from: 0, to: percents.count, by: groupSize).map { start in
            let group = percents[start..<min(start + groupSize, percents.count)]
            let usable = group.filter(\.isFinite)
            guard !usable.isEmpty else { return 0 }
            return CPUMeter.level(forPercent: usable.reduce(0, +) / Double(usable.count))
        }
    }
}

/// How the heatmap lays its tiles out.
public enum HeatmapGrid {
    /// Rows and columns for `count` tiles: up to four in one row, then two
    /// rows, then three, which is as many 5pt tiles as 18pt of height holds.
    /// The last row may be short.
    public static func layout(count: Int) -> (rows: Int, columns: Int) {
        let count = max(1, count)
        let rows = min(3, (count + 3) / 4)
        let columns = (count + rows - 1) / rows
        return (rows, columns)
    }
}

extension CPUMeter {
    /// `level` held to 0 through `steps`.
    static func clamp(_ level: Int) -> Int {
        min(max(0, level), steps)
    }
}

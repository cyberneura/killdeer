import Foundation

/// How the menu bar item shows the machine's figures. Chosen from the menu or
/// the settings window, and kept in the user defaults under `defaultsKey`.
///
/// Which figure goes where is not the style's choice: it takes as many
/// parameters as it has places for from the front of the user's order, through
/// `slots(order:historyRows:)`. "First" and "second" below are places in that
/// order.
///
/// Every style is drawn from quantised levels, `SystemReadings.level`, so
/// that the image can only ever be one of a small number of pictures; the two
/// per-core styles draw one level per core instead, and the history graph
/// draws past readings on its own scale. The drawing lives in the app, where
/// AppKit is; what is here is the choice and the arithmetic behind each
/// picture, which is what can be tested without a screen.
public enum MeterStyle: String, CaseIterable, Sendable {
    /// The bird with the upright gauge beside it, as the app first shipped.
    case birdWithGauge = "bird-with-gauge"
    /// Two concentric rings filling clockwise from seven o'clock round to
    /// five: the first parameter outside, the second inside.
    case ringGauge = "ring-gauge"
    /// The bird on its own, beating its wing faster the higher the first
    /// parameter stands.
    case flappingBird = "flapping-bird"
    /// One upright bar per core, side by side like an equaliser.
    case coreBars = "core-bars"
    /// One tile per core, the darker the busier, with a meter beside them for
    /// the first parameter that is not the CPU.
    case coreHeatmap = "core-heatmap"
    /// New moon at the bottom of the scale, waxing to a full moon at the top.
    case moonPhase = "moon-phase"
    /// Sun, then cloud, rain and thunder as the first parameter climbs.
    case weather = "weather"
    /// A cup that fills with the first parameter and spills over at the top
    /// of its scale, steaming with the second.
    case coffeeCup = "coffee-cup"
    /// The last few minutes of the first two to four parameters, as small
    /// charts one above the other.
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
            return "The bird, with a gauge beside it that fills from the bottom in ten steps."
        case .ringGauge:
            return "Two rings that fill clockwise from seven o'clock round to five, like a speedometer: the first parameter outside, the second inside."
        case .flappingBird:
            return "The bird alone. It sits still at the bottom of the scale and beats its wing faster as the first parameter climbs."
        case .coreBars:
            return "One bar per core, so a single core pegged by one process stands out from an evenly busy machine. Always the CPU."
        case .coreHeatmap:
            return "One tile per core, darker the busier the core, with a thin meter at the right-hand edge for the first parameter that is not the CPU."
        case .moonPhase:
            return "A new moon at the bottom of the scale, waxing through a half moon to a full moon at the top."
        case .weather:
            return "Sun at the bottom of the scale, then a cloud, rain, and thunder at the top."
        case .coffeeCup:
            return "A cup that fills with the first parameter and spills over at the top of its scale; the higher the second, the more it steams."
        case .historyGraph:
            return "Charts of the last \(LoadHistory.capacity) readings, newest at the right, one row per parameter from the top of the order."
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
}

/// The temperature on the same ten steps as `CPUMeter`.
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

/// The readings of the last few polls, oldest first, for the history graph.
///
/// Kept whatever the style, so that switching to the graph shows the minutes
/// already gone rather than an empty chart that fills over the next five.
public struct LoadHistory: Equatable, Sendable {
    /// Readings kept: five minutes at the default ten-second poll, one point
    /// of the graph's width each.
    public static let capacity = 30

    /// A figure is nil where there was no reading: the CPU on the first poll,
    /// before two tick samples exist, and the temperature on every poll of a
    /// machine with no readable sensor.
    public private(set) var readings: [SystemReadings] = []

    public init() {}

    public mutating func append(_ reading: SystemReadings) {
        readings.append(reading)
        if readings.count > Self.capacity {
            readings.removeFirst(readings.count - Self.capacity)
        }
    }
}

/// The history graph's rows and scales: how high each reading stands in its
/// chart.
public enum HistoryGraph {
    /// Rows the graph can be set to. Two is as few as makes it a comparison,
    /// and four is every parameter there is.
    public static let rowChoices: ClosedRange<Int> = 2...4

    public static let defaultRows = 4

    /// The key the row count is stored under in the user defaults.
    public static let rowsDefaultsKey = "historyGraphRows"

    public static func clampedRows(_ rows: Int) -> Int {
        min(max(rows, rowChoices.lowerBound), rowChoices.upperBound)
    }

    /// Points of height each row has: what 18pt holds with a gap between the
    /// rows.
    public static func rowHeight(rows: Int) -> Int {
        switch clampedRows(rows) {
        case 2: return 7
        case 3: return 5
        default: return 4
        }
    }

    /// Points between two rows. It shrinks as the rows multiply, so that the
    /// rows keep the height.
    public static func rowGap(rows: Int) -> Double {
        switch clampedRows(rows) {
        case 2: return 2
        case 3: return 1
        default: return 0.5
        }
    }

    /// Steps in a row's scale. Two rows have a step per point, which stays
    /// sharp on a display with one pixel to the point. Three or four rows
    /// would be left with five or four steps that way, too few to tell 60%
    /// memory from 80%, so they step in half points: a pixel each on a Retina
    /// display, and a half-lit pixel on the others.
    public static func steps(rows: Int) -> Int {
        let rows = clampedRows(rows)
        return rows == 2 ? rowHeight(rows: rows) : 2 * rowHeight(rows: rows)
    }

    /// What the menu calls each row, top row first.
    public static func rowNames(count: Int) -> [String] {
        switch count {
        case ...0: return []
        case 1: return ["graph"]
        case 2: return ["top row", "bottom row"]
        case 3: return ["top row", "middle row", "bottom row"]
        default:
            return ["top row"] + (2..<count).map { "row \($0)" } + ["bottom row"]
        }
    }

    /// One level per reading on the scale of a graph of `rows` rows, padded
    /// at the front with nils to `capacity`, so that the newest is always at
    /// the right edge and the picture does not change width as the history
    /// fills. A missing reading stays nil, so that the chart breaks rather
    /// than dropping to the floor.
    public static func levels(_ history: LoadHistory, parameter: MeterParameter, rows: Int) -> [Int?] {
        let steps = steps(rows: rows)
        let kept = history.readings.suffix(LoadHistory.capacity).map { $0.level(of: parameter, steps: steps) }
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
    /// Spilling over the rim, at the top of the scale only.
    public let overflowing: Bool

    /// `steamLevel` is the second parameter's level and sets the steam.
    /// Without one the steam follows the cup, so that a poll with no reading
    /// for it still has a cup that steams.
    public static func forLevel(_ level: Int, steamLevel: Int? = nil) -> CoffeeCup {
        let level = CPUMeter.clamp(level)
        let steam: Int
        switch CPUMeter.clamp(steamLevel ?? level) {
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
/// Both rings share it.
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

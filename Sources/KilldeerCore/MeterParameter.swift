import Foundation

/// A figure the menu bar picture can show.
public enum MeterParameter: String, CaseIterable, Sendable {
    case cpu
    case temperature
    case memory
    case swap

    public var displayName: String {
        switch self {
        case .cpu: return "CPU"
        case .temperature: return "Temperature"
        case .memory: return "Memory"
        case .swap: return "Swap"
        }
    }

    /// One line on what the figure is, for the settings window.
    public var summary: String {
        switch self {
        case .cpu: return "Use of all cores together"
        case .temperature:
            return "Hottest chip sensor, \(Int(TemperatureMeter.range.lowerBound)) to \(Int(TemperatureMeter.range.upperBound)) °C"
        case .memory: return "Memory used, of the installed RAM"
        case .swap: return "Swap used, against the size of the RAM"
        }
    }
}

/// The order the parameters are offered to a style in. A style has room for
/// one, two or a few of them and takes them from the front.
public enum MeterParameterOrder {
    /// The CPU and the temperature lead because they are what moves when a
    /// process runs away. Memory and swap climb slowly and sit high on a
    /// healthy Mac, so a one-figure picture drawn from them hardly changes.
    public static let `default`: [MeterParameter] = [.cpu, .temperature, .memory, .swap]

    /// The key the order is stored under in the user defaults, as raw values.
    public static let defaultsKey = "meterParameterOrder"

    /// The stored order made whole: names this build does not know and
    /// repeats are dropped, and whatever is missing follows in the default
    /// order, so that a value written by another build cannot hide a
    /// parameter.
    public static func parse(_ stored: [String]?) -> [MeterParameter] {
        var order: [MeterParameter] = []
        for parameter in (stored ?? []).compactMap(MeterParameter.init(rawValue:)) where !order.contains(parameter) {
            order.append(parameter)
        }
        return order + `default`.filter { !order.contains($0) }
    }

    /// `order` with `parameter` moved `offset` places, stopping at the ends.
    public static func moving(
        _ parameter: MeterParameter, by offset: Int, in order: [MeterParameter]
    ) -> [MeterParameter] {
        guard let index = order.firstIndex(of: parameter) else { return order }
        let target = min(max(0, index + offset), order.count - 1)
        guard target != index else { return order }
        var moved = order
        moved.remove(at: index)
        moved.insert(parameter, at: target)
        return moved
    }

    /// The order the styles draw from. A Mac with no readable sensor never
    /// has a temperature, so the styles pass over it rather than spend their
    /// one place on a gauge that stays empty.
    public static func drawable(_ order: [MeterParameter], temperatureAvailable: Bool) -> [MeterParameter] {
        temperatureAvailable ? order : order.filter { $0 != .temperature }
    }
}

/// One parameter's place in a style's picture.
public struct MeterSlot: Equatable, Sendable {
    public let parameter: MeterParameter
    /// The part of the picture, as the menu names it beside the figure: there
    /// is no room in 18pt to label the picture itself.
    public let part: String

    public init(_ parameter: MeterParameter, part: String) {
        self.parameter = parameter
        self.part = part
    }
}

extension MeterStyle {
    /// Which parameters the style shows and where, for `order` with the
    /// highest priority first.
    ///
    /// The two per-core styles are pictures of the cores, which only the CPU
    /// has, so the order does not move them; the heatmap's side meter takes
    /// the first parameter that is not the CPU, the tiles being the CPU
    /// already.
    public func slots(order: [MeterParameter], historyRows: Int = HistoryGraph.defaultRows) -> [MeterSlot] {
        let parts: [String]
        switch self {
        case .birdWithGauge: parts = ["gauge"]
        case .flappingBird: parts = ["wing beat"]
        case .moonPhase: parts = ["moon"]
        case .weather: parts = ["weather"]
        case .ringGauge: parts = ["outer ring", "inner ring"]
        case .coffeeCup: parts = ["coffee", "steam"]
        case .coreBars:
            return [MeterSlot(.cpu, part: "bars")]
        case .coreHeatmap:
            let side = order.first { $0 != .cpu }.map { MeterSlot($0, part: "side meter") }
            return [MeterSlot(.cpu, part: "tiles")] + (side.map { [$0] } ?? [])
        case .historyGraph:
            parts = HistoryGraph.rowNames(count: min(HistoryGraph.clampedRows(historyRows), order.count))
        }
        return zip(order, parts).map { MeterSlot($0, part: $1) }
    }
}

/// One poll's figures for every parameter. nil where there was no reading.
public struct SystemReadings: Equatable, Sendable {
    public var cpuPercent: Double?
    public var temperatureCelsius: Double?
    public var memory: MemoryUsage?
    public var swap: SwapUsage?

    public init(
        cpuPercent: Double? = nil, temperatureCelsius: Double? = nil,
        memory: MemoryUsage? = nil, swap: SwapUsage? = nil
    ) {
        self.cpuPercent = cpuPercent
        self.temperatureCelsius = temperatureCelsius
        self.memory = memory
        self.swap = swap
    }

    /// 0 through `steps`, or nil without a reading, so that a picture can
    /// tell "nothing to show" from "at the bottom of the scale".
    public func level(of parameter: MeterParameter, steps: Int = CPUMeter.steps) -> Int? {
        switch parameter {
        case .cpu: return cpuPercent.map { CPUMeter.level(forPercent: $0, steps: steps) }
        case .temperature: return TemperatureMeter.level(forCelsius: temperatureCelsius, steps: steps)
        case .memory: return memory.map { CPUMeter.level(forPercent: $0.percent, steps: steps) }
        case .swap: return swap.map { CPUMeter.level(forPercent: $0.percentOfMemory, steps: steps) }
        }
    }
}

/// The levels one picture is drawn from, already sorted into the picture's
/// parts by the parameter order.
public struct MeterLevels: Hashable, Sendable {
    /// The first slot's level. 0 for the per-core styles and the history
    /// graph, which do not draw it, so that it does not change their pictures'
    /// cache keys.
    public var primary: Int
    /// The second slot's level; nil for a style with one slot, and when that
    /// slot has no reading.
    public var secondary: Int?
    /// One row of `HistoryGraph` levels per slot, top row first; empty for
    /// every style but the history graph.
    public var history: [[Int?]]

    public init(primary: Int = 0, secondary: Int? = nil, history: [[Int?]] = []) {
        self.primary = primary
        self.secondary = secondary
        self.history = history
    }

    public init(style: MeterStyle, slots: [MeterSlot], readings: SystemReadings, history: LoadHistory) {
        if style.usesHistory {
            self.init(history: slots.map {
                HistoryGraph.levels(history, parameter: $0.parameter, rows: slots.count)
            })
            return
        }
        let first = slots.first.flatMap { readings.level(of: $0.parameter) }
        self.init(
            primary: style.usesCores ? 0 : first ?? 0,
            secondary: slots.dropFirst().first.flatMap { readings.level(of: $0.parameter) }
        )
    }
}

/// The menu's line for each parameter.
public enum ParameterLine {
    /// One line per parameter of `order`, in that order, each naming the part
    /// of the picture it is drawn in when it is in the picture at all.
    public static func lines(order: [MeterParameter], slots: [MeterSlot], readings: SystemReadings) -> [String] {
        order.map { parameter in
            text(parameter, readings: readings, part: slots.first { $0.parameter == parameter }?.part)
        }
    }

    /// A dash stands in for a missing reading rather than the line being
    /// dropped: a line that comes and goes moves every menu item below it.
    public static func text(_ parameter: MeterParameter, readings: SystemReadings, part: String? = nil) -> String {
        var line = parameter.displayName + " " + (figure(parameter, readings: readings) ?? "—")
        if let part { line += " — " + part }
        return line
    }

    private static func figure(_ parameter: MeterParameter, readings: SystemReadings) -> String? {
        switch parameter {
        case .cpu:
            return readings.cpuPercent.map { String(format: "%.1f%%", $0) }
        case .temperature:
            return readings.temperatureCelsius.map { String(format: "%.1f °C", $0) }
        case .memory:
            return readings.memory.map {
                String(format: "%.1f%% (%@ of %@ GB)", $0.percent, gigabytes($0.usedBytes), gigabytes($0.totalBytes, trimmed: true))
            }
        case .swap:
            // The amount first: a share of the RAM is this app's own scale,
            // and the size on disk is what every other tool reports.
            return readings.swap.map {
                String(format: "%@ (%.0f%% of RAM)", ChromeFormatting.memory($0.usedBytes), $0.percentOfMemory)
            }
        }
    }

    /// `trimmed` drops the decimal from a whole number, for the installed
    /// RAM, which always is one.
    private static func gigabytes(_ bytes: UInt64, trimmed: Bool = false) -> String {
        let value = Double(bytes) / 1_073_741_824
        if trimmed, abs(value - value.rounded()) < 0.05 { return String(format: "%.0f", value) }
        return String(format: "%.1f", value)
    }

    /// The figures in words, for VoiceOver on the menu bar item.
    public static func spoken(order: [MeterParameter], readings: SystemReadings) -> [String] {
        order.compactMap { parameter in
            switch parameter {
            case .cpu: return readings.cpuPercent.map { String(format: "CPU %.0f%%", $0) }
            case .temperature: return readings.temperatureCelsius.map { String(format: "%.0f degrees Celsius", $0) }
            case .memory: return readings.memory.map { String(format: "memory %.0f%%", $0.percent) }
            case .swap: return readings.swap.map { String(format: "swap %.0f%% of memory", $0.percentOfMemory) }
            }
        }
    }
}

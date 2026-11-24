import Foundation

/// How hard the system says it is working to stay cool.
///
/// A copy of `ProcessInfo.ThermalState` that is ordered, so that "serious or
/// worse" is a comparison, and that settles what a state unknown to this
/// build means in one place.
public enum ThermalPressure: Int, Sendable, Comparable, CaseIterable {
    case nominal, fair, serious, critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        // A state this build does not know is warned about rather than
        // passed over: a missed warning costs more than a spurious one.
        @unknown default: self = .serious
        }
    }

    public static func < (lhs: ThermalPressure, rhs: ThermalPressure) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Whether the system is holding performance back to shed heat.
    ///
    /// `serious` is where Apple's description of the states first says that
    /// performance is affected. `fair` is a warm machine with its fans up and
    /// comes and goes during ordinary work, so warning there would be noise.
    public var isThrottling: Bool { self >= .serious }
}

/// Decides when a busy CPU has become a CPU stuck at full load.
///
/// One reading at 100% is a compile or a page load. The warning is for load
/// that stays there, so the readings have to hold for `sustain` seconds first,
/// and once warned the state is kept until the load drops clearly below the
/// line rather than flickering with every reading either side of it.
public struct PeggedCPUDetector: Equatable, Sendable {
    /// A spin loop on every core reads 100.0%, measured. The margin is for a
    /// reading in which something yielded for a moment, which would otherwise
    /// restart the run.
    public static let defaultThreshold: Double = 95
    public static let defaultRelease: Double = 85
    public static let defaultSustain: TimeInterval = 30

    public let threshold: Double
    public let release: Double
    public let sustain: TimeInterval

    public private(set) var isPegged = false
    private var heldFor: TimeInterval = 0

    public init(
        threshold: Double = defaultThreshold,
        release: Double = defaultRelease,
        sustain: TimeInterval = defaultSustain
    ) {
        self.threshold = threshold
        self.release = min(release, threshold)
        self.sustain = sustain
    }

    /// Takes one reading, which is the average over the `interval` seconds
    /// since the reading before it, and returns whether the CPU now counts as
    /// pegged.
    ///
    /// Each reading at or over the threshold therefore stands for that much
    /// time at full load: at the default ten-second poll the third one in a
    /// row passes thirty seconds, and at a one-minute poll the first does.
    /// `interval` is the time that really passed between the two samples, not
    /// the configured poll: a poll also waits for a process scan of a second
    /// or more, and counting only the configured part would warn late.
    ///
    /// nil is a poll whose sample failed. Nothing is known about that stretch,
    /// so a run that has not yet warned starts again, while a warning already
    /// given stays until a reading shows the load has gone.
    public mutating func update(cpuPercent: Double?, interval: TimeInterval) -> Bool {
        guard let cpuPercent, cpuPercent.isFinite else {
            if !isPegged { heldFor = 0 }
            return isPegged
        }
        if isPegged {
            if cpuPercent < release {
                isPegged = false
                heldFor = 0
            }
        } else if cpuPercent >= threshold {
            heldFor += max(0, interval)
            isPegged = heldFor >= sustain
        } else {
            heldFor = 0
        }
        return isPegged
    }
}

/// The two ways the whole machine, rather than one process, is in trouble.
public struct SystemStrain: Equatable, Sendable {
    public var cpuPegged: Bool
    public var thermal: ThermalPressure

    public init(cpuPegged: Bool = false, thermal: ThermalPressure = .nominal) {
        self.cpuPegged = cpuPegged
        self.thermal = thermal
    }

    public var isThrottled: Bool { thermal.isThrottling }
    public var isWarning: Bool { cpuPegged || isThrottled }

    /// The menu's line for the current state, or nil when there is nothing to
    /// warn about.
    public var menuText: String? {
        var parts: [String] = []
        if cpuPegged { parts.append("CPU stuck at full load") }
        if isThrottled {
            parts.append(thermal == .critical ? "Thermal throttling (critical)" : "Thermal throttling")
        }
        return parts.isEmpty ? nil : "⚠ " + parts.joined(separator: " · ")
    }

    /// What to announce on the way from `previous` to this state: one entry
    /// per condition that has just begun. A condition that carries on, or
    /// ends, is not announced again.
    public func notifications(since previous: SystemStrain) -> [StrainNotification] {
        var result: [StrainNotification] = []
        if cpuPegged, !previous.cpuPegged { result.append(.cpuPegged) }
        if isThrottled, !previous.isThrottled { result.append(.thermalThrottling) }
        return result
    }
}

public enum StrainNotification: Sendable, Equatable {
    case cpuPegged
    case thermalThrottling

    public var title: String {
        switch self {
        case .cpuPegged: return "CPU stuck at full load"
        case .thermalThrottling: return "This Mac is being thermally throttled"
        }
    }

    public var body: String {
        switch self {
        case .cpuPegged:
            return "The whole machine has been busy for a while. Open Killdeer to see the top processes."
        case .thermalThrottling:
            return "The system is slowing down to shed heat. Open Killdeer to see what is running."
        }
    }
}

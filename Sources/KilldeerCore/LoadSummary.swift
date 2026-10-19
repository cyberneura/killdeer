import Foundation

/// How full the CPU meter beside the menu bar bird is drawn.
///
/// The meter is quantised to a fixed number of steps rather than drawn at the
/// exact percentage so that the app can render every possible image once at
/// launch and pick one per poll, instead of rasterising a new one each time the
/// figure moves by a tenth of a percent.
public enum CPUMeter {
    /// Ten steps of ten percent: fine enough to tell idle from busy from
    /// pegged at 18pt, coarse enough that the icon is not redrawn on noise.
    public static let steps = 10

    /// The number of filled steps, from 0 to `steps`.
    ///
    /// nil, which is the first poll before two tick samples exist, draws an
    /// empty meter rather than hiding it, so the menu bar item does not change
    /// width a few seconds after launch.
    ///
    /// Anything above zero shows at least one step. A machine at 4% is not
    /// idle in the sense of "nothing is running", and an empty meter beside a
    /// non-zero figure in the menu would read as the meter being broken.
    public static func level(forPercent percent: Double?) -> Int {
        guard let percent, percent.isFinite, percent > 0 else { return 0 }
        let clamped = min(percent, 100)
        let filled = Int((clamped / 100 * Double(steps)).rounded())
        return min(steps, max(1, filled))
    }
}

/// The processes using the most CPU right now, whatever they are.
///
/// Separate from the runaway findings on purpose. Those are a judgement, with a
/// threshold and Chrome-specific scoring, and stay empty on a machine that is
/// merely busy. This is a plain ranking: it answers "what is the fan spinning
/// for" when nothing has crossed the line yet.
public enum TopProcesses {
    /// The busiest processes, highest first, at most `limit` of them.
    ///
    /// Processes below `minimumCPUPercent` are left out so an idle machine
    /// shows a short list, or none, rather than five rows of 0.0%. Ties are
    /// broken by PID so that two equally busy processes do not swap places
    /// from one poll to the next.
    public static func select(
        from findings: [ProcessFinding],
        limit: Int = 5,
        minimumCPUPercent: Double = 1
    ) -> [ProcessFinding] {
        guard limit > 0 else { return [] }
        return findings
            .filter { $0.cpuPercent.isFinite && $0.cpuPercent >= minimumCPUPercent }
            .sorted {
                if $0.cpuPercent != $1.cpuPercent { return $0.cpuPercent > $1.cpuPercent }
                return $0.process.identity.pid < $1.process.identity.pid
            }
            .prefix(limit)
            .map { $0 }
    }
}

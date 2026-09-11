import Foundation

public struct ProcessDetector: Sendable {
    public let configuration: DetectionConfiguration

    public init(configuration: DetectionConfiguration = .init()) {
        self.configuration = configuration
    }

    public func sample(using enumerator: ProcessEnumerator = .init()) throws -> [ProcessFinding] {
        let first = try enumerator.snapshots()
        Thread.sleep(forTimeInterval: configuration.sampleInterval)
        let second = try enumerator.snapshots()
        return findings(previous: first, current: second, elapsed: configuration.sampleInterval)
    }

    public func findings(previous: [ProcessSnapshot], current: [ProcessSnapshot], elapsed: TimeInterval) -> [ProcessFinding] {
        let prior = Dictionary(uniqueKeysWithValues: previous.map { ($0.identity, $0) })
        let byPID = Dictionary(uniqueKeysWithValues: current.map { ($0.identity.pid, $0) })

        return current.map { process in
            let oldCPU = prior[process.identity]?.totalCPUTimeNanoseconds ?? process.totalCPUTimeNanoseconds
            let delta = process.totalCPUTimeNanoseconds >= oldCPU ? process.totalCPUTimeNanoseconds - oldCPU : 0
            let cpu = elapsed > 0 ? Double(delta) / (elapsed * 1_000_000_000) * 100 : 0
            let orphan = isDisconnectedChromeHelper(process, byPID: byPID)
            var score = 0
            var reasons: [String] = []
            if cpu >= configuration.cpuThresholdPercent {
                score += 50
                reasons.append(String(format: "CPU %.1f%% >= %.1f%%", cpu, configuration.cpuThresholdPercent))
            }
            if orphan {
                score += 40
                reasons.append("Chrome helper has no connected Chrome ancestor")
            }
            if orphan, cpu >= max(10, configuration.cpuThresholdPercent / 4) {
                score += 20
                reasons.append("orphan helper is actively consuming CPU")
            }
            return ProcessFinding(process: process, cpuPercent: cpu, isOrphanChromeHelper: orphan, score: score, reasons: reasons)
        }
        .sorted { ($0.score, $0.cpuPercent) > ($1.score, $1.cpuPercent) }
    }

    /// Deliberately narrower than `ChromeInspector`, which recognises every
    /// Chromium-derived browser. Widening the ancestor test here would change
    /// which processes `clean-chrome` terminates.
    private func isDisconnectedChromeHelper(_ process: ProcessSnapshot, byPID: [pid_t: ProcessSnapshot]) -> Bool {
        guard isChromeHelper(process) else { return false }
        return ProcessAncestry.nearestAncestor(of: process, byPID: byPID, matching: isChromeBrowser) == nil
    }

    private func isChromeHelper(_ process: ProcessSnapshot) -> Bool {
        let text = ([process.name] + process.arguments).joined(separator: " ").lowercased()
        return text.contains("chrome helper") || (text.contains("google chrome") && text.contains("--type="))
    }

    private func isChromeBrowser(_ process: ProcessSnapshot) -> Bool {
        let name = process.name.lowercased()
        let executable = process.arguments.first?.lowercased() ?? ""
        return (name == "google chrome" || executable.hasSuffix("/google chrome"))
            && !process.arguments.contains(where: { $0.hasPrefix("--type=") })
    }
}

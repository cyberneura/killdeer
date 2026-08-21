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
        let currentPIDs = Set(current.map { $0.identity.pid })
        let byPID = Dictionary(uniqueKeysWithValues: current.map { ($0.identity.pid, $0) })

        return current.map { process in
            let oldCPU = prior[process.identity]?.totalCPUTimeNanoseconds ?? process.totalCPUTimeNanoseconds
            let delta = process.totalCPUTimeNanoseconds >= oldCPU ? process.totalCPUTimeNanoseconds - oldCPU : 0
            let cpu = elapsed > 0 ? Double(delta) / (elapsed * 1_000_000_000) * 100 : 0
            let orphan = isDisconnectedChromeHelper(process, currentPIDs: currentPIDs, byPID: byPID)
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

    private func isDisconnectedChromeHelper(
        _ process: ProcessSnapshot,
        currentPIDs: Set<pid_t>,
        byPID: [pid_t: ProcessSnapshot]
    ) -> Bool {
        guard isChromeHelper(process) else { return false }
        if process.parentPID <= 1 || !currentPIDs.contains(process.parentPID) { return true }

        var visited: Set<pid_t> = [process.identity.pid]
        var parent = process.parentPID
        for _ in 0..<32 {
            guard parent > 1, !visited.contains(parent), let ancestor = byPID[parent] else { return true }
            if isChromeBrowser(ancestor) { return false }
            visited.insert(parent)
            parent = ancestor.parentPID
        }
        return true
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

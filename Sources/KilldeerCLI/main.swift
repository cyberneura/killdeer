import Foundation
import KilldeerCore

private func usage() {
    print("""
    Usage:
      killdeer scan [--cpu PERCENT] [--interval SECONDS] [--all]
      killdeer kill PID [PID ...]
      killdeer clean-chrome [--yes] [--cpu PERCENT] [--interval SECONDS]

    scan          Show runaway findings (or every sampled process with --all).
    kill          Terminate selected PIDs (SIGTERM, then SIGKILL after 3 seconds).
    clean-chrome  Terminate every disconnected Chrome Helper; prompts unless --yes.
    """)
}

private func value(after option: String, in arguments: [String]) -> Double? {
    guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else { return nil }
    return Double(arguments[index + 1])
}

private func configuration(_ arguments: [String]) -> DetectionConfiguration {
    DetectionConfiguration(
        cpuThresholdPercent: value(after: "--cpu", in: arguments) ?? 80,
        sampleInterval: value(after: "--interval", in: arguments) ?? 1
    )
}

private func render(_ findings: [ProcessFinding]) {
    if findings.isEmpty {
        print("No matching processes detected.")
        return
    }
    func column(_ value: String, width: Int) -> String {
        String(value.prefix(width)).padding(toLength: width, withPad: " ", startingAt: 0)
    }
    print("\(column("PID", width: 7)) \(column("CPU%", width: 7)) \(column("SCORE", width: 5)) \(column("NAME", width: 30)) ARGUMENTS")
    for item in findings {
        let args = item.process.arguments.joined(separator: " ")
        let cpu = String(format: "%.1f", item.cpuPercent)
        print("\(column(String(item.process.identity.pid), width: 7)) \(column(cpu, width: 7)) \(column(String(item.score), width: 5)) \(column(item.process.name, width: 30)) \(args)")
        if !item.reasons.isEmpty { print("        \(item.reasons.joined(separator: "; "))") }
    }
}

private func terminate(_ findings: [ProcessFinding]) -> Int32 {
    let terminator = ProcessTerminator()
    var failed = false
    for item in findings {
        do {
            try terminator.terminate(item.process.identity)
            print("Terminated \(item.process.identity.pid) \(item.process.name)")
        } catch {
            failed = true
            fputs("killdeer: \(error.localizedDescription)\n", stderr)
        }
    }
    return failed ? 1 : 0
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage(); exit(2) }

do {
    switch command {
    case "scan":
        let findings = try ProcessDetector(configuration: configuration(arguments)).sample()
        render(arguments.contains("--all") ? findings : findings.filter(\.isRunaway))
    case "kill":
        let enumerator = ProcessEnumerator()
        let requested = Set(arguments.dropFirst().compactMap(Int32.init))
        guard !requested.isEmpty else { usage(); exit(2) }
        let selected = try enumerator.snapshots().filter { requested.contains($0.identity.pid) }.map {
            ProcessFinding(process: $0, cpuPercent: 0, isOrphanChromeHelper: false, score: 0, reasons: [])
        }
        let found = Set(selected.map { $0.process.identity.pid })
        for missing in requested.subtracting(found).sorted() { fputs("killdeer: PID \(missing) not found or inaccessible\n", stderr) }
        exit(terminate(selected))
    case "clean-chrome":
        let findings = try ProcessDetector(configuration: configuration(arguments)).sample().filter(\.isOrphanChromeHelper)
        render(findings)
        guard !findings.isEmpty else { exit(0) }
        if !arguments.contains("--yes") {
            print("Terminate all \(findings.count) orphan Chrome helper(s)? [y/N] ", terminator: "")
            guard readLine()?.lowercased() == "y" else { print("Cancelled."); exit(0) }
        }
        exit(terminate(findings))
    case "help", "--help", "-h": usage()
    default: usage(); exit(2)
    }
} catch {
    fputs("killdeer: \(error.localizedDescription)\n", stderr)
    exit(1)
}

import Foundation
import KilldeerCore

private func usage() {
    print("""
    Usage:
      killdeer scan [--cpu PERCENT] [--interval SECONDS] [--all]
      killdeer kill PID [PID ...]
      killdeer clean-chrome [--yes] [--cpu PERCENT] [--interval SECONDS]
      killdeer chrome [--all] [--json] [--probe] [--interval SECONDS]
      killdeer chrome kill PID [--yes]

    scan          Show runaway findings (or every sampled process with --all).
    kill          Terminate selected PIDs (SIGTERM, then SIGKILL after 3 seconds).
    clean-chrome  Terminate every disconnected Chrome Helper; prompts unless --yes.
    chrome        List running Chromium-family browsers by instance: profile,
                  headless state, debugging port and who launched them.
                  --all adds a line per helper, --probe checks the debugging
                  port answers, and `chrome kill PID` takes down one instance.
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

private func column(_ value: String, width: Int) -> String {
    String(value.prefix(width)).padding(toLength: width, withPad: " ", startingAt: 0)
}

private func render(_ findings: [ProcessFinding]) {
    if findings.isEmpty {
        print("No matching processes detected.")
        return
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

private func renderChrome(_ instances: [ChromeInstance], showHelpers: Bool, probe: Bool) {
    if instances.isEmpty {
        print("No Chromium-family browsers are running.")
        return
    }
    let prober = ChromeDebugProbe()
    let now = Date()

    for (index, instance) in instances.enumerated() {
        if index > 0 { print("") }
        let pid = instance.browser.map { String($0.identity.pid) } ?? "—"
        print("\(instance.displayName)  PID \(pid)")
        print("  profile        \(instance.profileDescription)")
        print("  user-data-dir  \(instance.userDataDirectory ?? "unknown")")
        print("  headless       \(instance.isHeadless ? "yes" : "no")")

        switch instance.remoteDebugging {
        case .pipe:
            print("  debugging      pipe (--remote-debugging-pipe)")
        case .port:
            // A requested port of 0 means the browser chose one; printing the 0
            // would read as "no port" when it is the opposite.
            let resolved = instance.remoteDebuggingPort
            var line = "  debugging      port \(resolved.map(String.init) ?? "unresolved")"
            // An answer on the port is only this browser's if this browser is
            // the one holding it and no other instance is holding it too.
            let target = probe && instance.ownsDebugEndpoint ? resolved.flatMap { prober.probe(port: $0) } : nil
            if resolved == nil {
                // Nothing to check the browser against.
            } else if instance.sharesDebugPort {
                line += " — also claimed by another instance below"
            } else if !instance.isListeningOnDebugPort {
                line += " — requested, but this browser is not listening on it"
            } else if probe {
                line += target.map { " — reachable, \($0.browser)" } ?? " — not answering"
            }
            print(line)
            if let socket = target?.webSocketDebuggerURL {
                print("  websocket      \(socket)")
            }
        case nil:
            print("  debugging      off")
        }

        if !instance.automationFlags.isEmpty {
            print("  automation     \(instance.automationFlags.joined(separator: " "))")
        }
        if let launchedBy = instance.launchedBy {
            print("  launched by    \(launchedBy)")
        }
        if let started = instance.startTime {
            print("  started        \(ChromeFormatting.absoluteTime(started)) (\(ChromeFormatting.relativeTime(started, now: now)))")
        }
        print(String(format: "  processes      %d helper(s), %.1f%% CPU, %@",
                     instance.helpers.count,
                     instance.totalCPUPercent,
                     ChromeFormatting.memory(instance.totalResidentMemoryBytes)))

        guard showHelpers else { continue }
        for process in instance.allProcesses {
            let cpu = String(format: "%.1f%%", process.cpuPercent)
            print("    \(column(String(process.identity.pid), width: 7)) \(column(process.role.displayName, width: 26)) \(column(cpu, width: 7)) \(ChromeFormatting.memory(process.residentMemoryBytes))")
        }
    }
}

private func chromeJSON(_ instances: [ChromeInstance], probe: Bool) throws -> String {
    let prober = ChromeDebugProbe()
    var probes: [Int: ChromeDebugTarget?] = [:]
    if probe {
        for port in instances.compactMap(\.remoteDebuggingPort) { probes[port] = prober.probe(port: port) }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let report = ChromeReport(instances: instances, probes: probes)
    return String(decoding: try encoder.encode(report), as: UTF8.self)
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
    case "chrome":
        let rest = Array(arguments.dropFirst())
        if rest.first == "kill" {
            let requested = Set(rest.dropFirst().compactMap(Int32.init))
            guard !requested.isEmpty else { usage(); exit(2) }
            let instances = try ChromeInspector().sample(configuration: configuration(arguments))
            // Matching helpers too means a PID copied from `--all` output kills
            // the instance it belongs to, rather than failing with "not a browser".
            let targets = instances.filter { instance in
                instance.allProcesses.contains { requested.contains($0.identity.pid) }
            }
            guard !targets.isEmpty else {
                fputs("killdeer: no Chrome instance owns \(requested.sorted().map(String.init).joined(separator: ", "))\n", stderr)
                exit(1)
            }
            for instance in targets { print(instance.menuSummary) }
            if !arguments.contains("--yes") {
                print("Terminate \(targets.count) instance(s)? [y/N] ", terminator: "")
                guard readLine()?.lowercased() == "y" else { print("Cancelled."); exit(0) }
            }
            // A running instance dies from its browser process alone: Chrome
            // tears its own helpers down on exit, and killing them first makes
            // it report a crash on next launch.
            //
            // The orphan rows are not instances. They collect every stray of
            // one browser kind, and those strays have nothing to do with each
            // other, so only the PIDs actually named are signalled there.
            let victims = targets.flatMap { instance -> [ChromeProcess] in
                if let browser = instance.browser { return [browser] }
                return instance.helpers.filter { requested.contains($0.identity.pid) }
            }
            exit(terminate(victims.map {
                ProcessFinding(process: $0.snapshot, cpuPercent: 0, isOrphanChromeHelper: false, score: 0, reasons: [])
            }))
        }
        let instances = try ChromeInspector().sample(configuration: configuration(arguments))
        if arguments.contains("--json") {
            print(try chromeJSON(instances, probe: arguments.contains("--probe")))
        } else {
            renderChrome(instances, showHelpers: arguments.contains("--all"), probe: arguments.contains("--probe"))
        }
    case "help", "--help", "-h": usage()
    default: usage(); exit(2)
    }
} catch {
    fputs("killdeer: \(error.localizedDescription)\n", stderr)
    exit(1)
}

import Darwin
import Foundation

/// The coding agents whose processes are grouped into instances.
public enum AgentKind: String, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case codex

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// Programs that run a script named in their arguments. An agent
    /// installed from npm is one of these running the agent's script, and the
    /// file the kernel recorded says only which runtime it is.
    private static let scriptRuntimes: Set<String> = ["node", "bun"]

    /// What agent a process is, from the file the kernel recorded as executed.
    ///
    /// Not from the process name. Claude Code's installer links `claude` to a
    /// file named after its version, and the name the kernel reports for the
    /// process is that file's: "2.1.331". The executed path keeps the link's
    /// own name.
    ///
    /// The match is on case: the desktop apps' main executables are `Claude`
    /// and `Codex`, and those are apps with a window, not agent sessions.
    public static func detect(executablePath: String, arguments: [String]) -> AgentKind? {
        guard !executablePath.isEmpty else { return nil }
        if let kind = kind(ofProgram: executablePath) {
            return embeddedTool(executablePath: executablePath, arguments: arguments) == nil ? kind : nil
        }
        guard scriptRuntimes.contains(fileName(executablePath)),
              let script = arguments.dropFirst().first(where: { !$0.hasPrefix("-") })
        else { return nil }
        if script.contains("/@anthropic-ai/claude-code/") { return .claudeCode }
        if script.contains("/@openai/codex/") { return .codex }
        return kind(ofProgram: script)
    }

    /// The tool an agent's program is running as, when it is not running as
    /// the agent.
    ///
    /// Claude Code carries its own search tools inside its one executable and
    /// picks between them by `argv[0]`: its shell runs `grep` and `find` as
    /// that same file started under the name `ugrep`, `rg` or `bfs`. Going by
    /// the file alone would list every search as an agent, and a `grep -r`
    /// over a large tree is exactly the load this list is there to explain.
    public static func embeddedTool(executablePath: String, arguments: [String]) -> String? {
        guard kind(ofProgram: executablePath) == .claudeCode, let invokedAs = arguments.first else { return nil }
        let name = fileName(invokedAs)
        // Started by its full path, the name is the file's own.
        guard !name.isEmpty, name != "claude", name != fileName(executablePath) else { return nil }
        return name
    }

    private static func kind(ofProgram path: String) -> AgentKind? {
        let file = fileName(path)
        // The second test is for a link that was resolved before the exec:
        // the path is then the versioned file itself.
        if file == "claude" || path.contains("/claude/versions/") { return .claudeCode }
        if file == "codex" || file.hasPrefix("codex-") { return .codex }
        return nil
    }

    private static func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

/// One process of an agent instance: the agent itself, or something it
/// started.
public struct AgentProcess: Sendable {
    public let snapshot: ProcessSnapshot
    public let cpuPercent: Double
    /// Set when the process is an agent's own program rather than something
    /// an agent started.
    public let kind: AgentKind?

    public init(snapshot: ProcessSnapshot, cpuPercent: Double, kind: AgentKind?) {
        self.snapshot = snapshot
        self.cpuPercent = cpuPercent
        self.kind = kind
    }

    public var identity: ProcessIdentity { snapshot.identity }
    public var residentMemoryBytes: UInt64 { snapshot.residentMemoryBytes }

    private static let scriptRuntimePrefixes = ["node", "bun", "deno", "python", "ruby", "perl"]

    /// What to call the process in a list. An agent goes by its product name,
    /// its process name being a version number, and a script runtime by its
    /// script as well: a list of five rows all reading "node" says nothing
    /// about which is the MCP server and which the build.
    public var displayName: String {
        if let kind { return kind.displayName }
        if let tool = AgentKind.embeddedTool(executablePath: snapshot.executablePath, arguments: snapshot.arguments) {
            return tool
        }
        let name = snapshot.name
        let lowered = name.lowercased()
        guard Self.scriptRuntimePrefixes.contains(where: lowered.hasPrefix),
              let script = Self.scriptName(in: snapshot.arguments)
        else { return name }
        return "\(name) \(script)"
    }

    /// The script a runtime was given, when the argument right after the
    /// program is plainly a file.
    ///
    /// Only that one argument, and only if it looks like a path. After
    /// `node -e` or `python -c` the next word is the program text itself,
    /// which can hold a token, and this name goes into the menu and the
    /// terminal.
    private static func scriptName(in arguments: [String]) -> String? {
        guard arguments.count > 1 else { return nil }
        let candidate = arguments[1]
        guard !candidate.hasPrefix("-"), candidate.count <= 255,
              !candidate.contains(where: { $0.isWhitespace || $0.isNewline })
        else { return nil }
        let name = (candidate as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// One line for the menu.
    public var menuSummary: String {
        [displayName, String(format: "%.1f%% CPU", cpuPercent), ChromeFormatting.memory(residentMemoryBytes)]
            .joined(separator: " — ")
    }
}

/// One running agent session: the agent's process and everything under it.
public struct AgentInstance: Sendable {
    public let kind: AgentKind
    public let root: AgentProcess
    /// Every process below the agent, busiest first. An agent started by this
    /// one, `codex exec` from a Claude Code session say, is in here rather
    /// than an instance of its own: its load is this session's doing.
    public let descendants: [AgentProcess]
    /// The directory the agent works in, which is the project the session is
    /// about and the one thing that tells twenty sessions apart.
    public let workingDirectory: String?
    /// `workingDirectory` shortened for one line: its last component, or `~`.
    public let directoryName: String?
    /// The app or tool the session was started from.
    public let launchedBy: String?
    /// How the agent was started, where that changes what it is: a session
    /// with nobody typing into it, a server other tools talk to.
    public let tags: [String]

    /// Stable across polls so SwiftUI keeps a submenu open while the list
    /// behind it is refreshed.
    public var id: String { "pid:\(root.identity.pid)" }

    public var allProcesses: [AgentProcess] { [root] + descendants }
    public var totalCPUPercent: Double { allProcesses.reduce(0) { $0 + $1.cpuPercent } }
    public var totalResidentMemoryBytes: UInt64 { allProcesses.reduce(0) { $0 &+ $1.residentMemoryBytes } }
    public var startTime: Date { root.identity.startTime }

    /// One line for the menu bar, where there is no room for a table.
    public var menuSummary: String {
        var parts = [kind.displayName]
        if let directoryName { parts.append(directoryName) }
        let count = allProcesses.count
        parts.append("\(count) process\(count == 1 ? "" : "es")")
        parts.append(String(format: "%.1f%% CPU", totalCPUPercent))
        parts.append(ChromeFormatting.memory(totalResidentMemoryBytes))
        if !tags.isEmpty { parts.append("[\(tags.joined(separator: ", "))]") }
        return parts.joined(separator: " — ")
    }

    /// The first `limit` processes for a list, the agent itself first, and
    /// how many were left out.
    public func listedProcesses(limit: Int) -> (shown: [AgentProcess], hidden: Int) {
        let all = allProcesses
        let shown = Array(all.prefix(max(1, limit)))
        return (shown, all.count - shown.count)
    }
}

public struct AgentInspector: Sendable {
    private let workingDirectory: @Sendable (pid_t) -> String?
    private let kernelProcess: @Sendable (pid_t) -> KernelProcess?
    private let homeDirectory: String

    /// - Parameters:
    ///   - workingDirectory: the current directory of a process, or nil when
    ///     it cannot be read.
    ///   - kernelProcess: the parent and name of a process the snapshots do
    ///     not hold; see `launcher`.
    public init(
        workingDirectory: @escaping @Sendable (pid_t) -> String? = { ProcessLookup.workingDirectory(of: $0) },
        kernelProcess: @escaping @Sendable (pid_t) -> KernelProcess? = { ProcessLookup.kernelProcess($0) },
        homeDirectory: String = NSHomeDirectory()
    ) {
        self.workingDirectory = workingDirectory
        self.kernelProcess = kernelProcess
        self.homeDirectory = homeDirectory
    }

    /// Samples the machine and groups the agent processes it finds, with CPU
    /// figures measured as everywhere else in Killdeer.
    public func sample(configuration: DetectionConfiguration = .init()) throws -> [AgentInstance] {
        instances(from: try ProcessDetector(configuration: configuration).sample())
    }

    public func instances(from findings: [ProcessFinding]) -> [AgentInstance] {
        var kinds: [pid_t: AgentKind] = [:]
        for finding in findings {
            let process = finding.process
            if let kind = AgentKind.detect(executablePath: process.executablePath, arguments: process.arguments) {
                kinds[process.identity.pid] = kind
            }
        }
        guard !kinds.isEmpty else { return [] }

        let byPID = Dictionary(findings.map { ($0.process.identity.pid, $0.process) }, uniquingKeysWith: { first, _ in first })
        let sessions = Self.sessionRoots(of: byPID, agents: Set(kinds.keys))
        var roots: [ProcessFinding] = []
        var descendantsByRoot: [pid_t: [AgentProcess]] = [:]
        for finding in findings {
            let pid = finding.process.identity.pid
            guard let root = sessions[pid] else { continue }
            if root == pid {
                roots.append(finding)
            } else {
                descendantsByRoot[root, default: []].append(
                    AgentProcess(snapshot: finding.process, cpuPercent: finding.cpuPercent, kind: kinds[pid])
                )
            }
        }

        return roots.compactMap { finding -> AgentInstance? in
            let process = finding.process
            guard let kind = kinds[process.identity.pid] else { return nil }
            let directory = Self.workingRoot(
                kind: kind, arguments: process.arguments, currentDirectory: workingDirectory(process.identity.pid)
            )
            return AgentInstance(
                kind: kind,
                root: AgentProcess(snapshot: process, cpuPercent: finding.cpuPercent, kind: kind),
                // PID breaks ties so that two idle processes do not swap
                // places from one poll to the next.
                descendants: (descendantsByRoot[process.identity.pid] ?? []).sorted {
                    if $0.cpuPercent != $1.cpuPercent { return $0.cpuPercent > $1.cpuPercent }
                    return $0.identity.pid < $1.identity.pid
                },
                workingDirectory: directory,
                directoryName: directory.map { Self.directoryName(for: $0, home: homeDirectory) },
                launchedBy: launcher(of: process, byPID: byPID),
                tags: Self.tags(kind: kind, arguments: process.arguments)
            )
        }
        .sorted { first, second in
            let kindOrder = AgentKind.allCases
            let firstKind = kindOrder.firstIndex(of: first.kind) ?? 0
            let secondKind = kindOrder.firstIndex(of: second.kind) ?? 0
            if firstKind != secondKind { return firstKind < secondKind }
            let firstName = first.directoryName?.lowercased() ?? ""
            let secondName = second.directoryName?.lowercased() ?? ""
            if firstName != secondName { return firstName < secondName }
            return first.root.identity.pid < second.root.identity.pid
        }
    }

    /// The session each process belongs to: the PID of the outermost agent
    /// at or above it. A process with no agent above it, and not one itself,
    /// has no entry.
    ///
    /// The outermost, not the nearest: a process under an agent that another
    /// agent started belongs to the session at the top. Each process is
    /// settled once, from the answer of its parent, so a deep tree costs no
    /// more than a shallow one and none of it is cut off by a depth limit.
    static func sessionRoots(of processes: [pid_t: ProcessSnapshot], agents: Set<pid_t>) -> [pid_t: pid_t] {
        var settled: [pid_t: pid_t?] = [:]
        // In PID order, so that parent links that loop, which a recycled PID
        // can produce in a snapshot, are cut at the same place on every poll.
        for start in processes.keys.sorted() {
            var path: [pid_t] = []
            var onPath: Set<pid_t> = []
            var inherited: pid_t?
            var current = start
            while current > 1, !onPath.contains(current), let process = processes[current] {
                if let known = settled[current] {
                    inherited = known
                    break
                }
                path.append(current)
                onPath.insert(current)
                current = process.parentPID
            }
            for pid in path.reversed() {
                inherited = inherited ?? (agents.contains(pid) ? pid : nil)
                // Not by subscript: assigning nil there would drop the entry
                // that records "looked at, and under no agent".
                settled.updateValue(inherited, forKey: pid)
            }
        }
        return settled.compactMapValues { $0 }
    }

    /// The directory the session is about. Codex can be pointed at a project
    /// with `-C` without being started in it; the process's own directory is
    /// then only where the command was typed.
    static func workingRoot(kind: AgentKind, arguments: [String], currentDirectory: String?) -> String? {
        guard kind == .codex, let given = directoryOption(in: arguments) else { return currentDirectory }
        if given.hasPrefix("/") { return URL(fileURLWithPath: given).standardized.path }
        guard let currentDirectory else { return given }
        return URL(fileURLWithPath: currentDirectory).appendingPathComponent(given).standardized.path
    }

    private static func directoryOption(in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated().dropFirst() {
            if argument.hasPrefix("--cd=") { return String(argument.dropFirst("--cd=".count)) }
            if argument == "-C" || argument == "--cd", arguments.indices.contains(index + 1) {
                return arguments[index + 1]
            }
        }
        return nil
    }

    static func directoryName(for path: String, home: String) -> String {
        if path == home { return "~" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    static func tags(kind: AgentKind, arguments: [String]) -> [String] {
        let rest = arguments.dropFirst()
        switch kind {
        case .claudeCode:
            var tags: [String] = []
            if rest.contains("-p") || rest.contains("--print") { tags.append("headless") }
            if rest.contains("--chrome-native-host") { tags.append("Chrome native host") }
            return tags
        case .codex:
            // The subcommand is the first word that is not an option. Two are
            // looked at because the first may be an option's value, or the
            // script when the agent runs under node.
            let words = rest.filter { !$0.hasPrefix("-") }.prefix(2)
            if words.contains("app-server") { return ["app server"] }
            if words.contains("mcp-server") { return ["MCP server"] }
            if words.contains("exec") { return ["headless"] }
            return []
        }
    }

    /// Names that say nothing about where a session was started: the shell
    /// and the login plumbing sit between every terminal and what runs in it.
    private static let uninformativeLaunchers: Set<String> = [
        "launchd", "loginwindow", "login", "sudo", "env", "script",
        "sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh",
    ]

    /// The outermost informative ancestor: the terminal or editor rather than
    /// the shell inside it.
    ///
    /// The snapshots are not enough for this walk. A terminal starts its
    /// shell through `login`, which runs as root, and a process of another
    /// user has no snapshot; the chain would end one step short of the
    /// terminal. `kernelProcess` fills that step in.
    private func launcher(of root: ProcessSnapshot, byPID: [pid_t: ProcessSnapshot]) -> String? {
        var names: [String] = []
        var visited: Set<pid_t> = [root.identity.pid]
        var parent = root.parentPID
        for _ in 0..<32 {
            guard parent > 1, !visited.contains(parent) else { break }
            let step: KernelProcess
            if let snapshot = byPID[parent] {
                step = KernelProcess(parentPID: snapshot.parentPID, name: snapshot.name)
            } else if let found = kernelProcess(parent) {
                step = found
            } else {
                break
            }
            names.append(step.name)
            visited.insert(parent)
            parent = step.parentPID
        }
        return names.last { name in
            // A login shell's name can carry the dash of its argv[0].
            let bare = name.hasPrefix("-") ? String(name.dropFirst()) : name
            return !Self.uninformativeLaunchers.contains(bare.lowercased())
        }
    }
}

/// What the kernel says of a process whoever owns it.
public struct KernelProcess: Sendable, Equatable {
    public let parentPID: pid_t
    public let name: String

    public init(parentPID: pid_t, name: String) {
        self.parentPID = parentPID
        self.name = name
    }
}

public enum ProcessLookup {
    /// The current directory of a process of the same user, or nil.
    public static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    /// The parent and the short name of any process. Unlike `proc_pidinfo`,
    /// which `ProcessEnumerator` reads everything else with, this answers for
    /// a process of another user too.
    public static func kernelProcess(_ pid: pid_t) -> KernelProcess? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        // A PID that is gone is not an error: the call succeeds and writes
        // nothing.
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafePointer(to: &info.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        return KernelProcess(parentPID: info.kp_eproc.e_ppid, name: name)
    }
}

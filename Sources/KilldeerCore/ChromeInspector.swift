import Foundation

public struct ChromeProcess: Sendable {
    public let snapshot: ProcessSnapshot
    public let commandLine: ChromeCommandLine
    public let cpuPercent: Double

    public var identity: ProcessIdentity { snapshot.identity }
    public var role: ChromeProcessRole { commandLine.role }
    public var kind: ChromeBrowserKind? { ChromeBrowserKind.detect(executablePath: commandLine.executablePath) }

    /// Identified by its executable rather than by the `--database` switch it
    /// normally carries. What it is does not depend on how it was invoked, and
    /// one launched without that switch still needs placing rather than
    /// dropping into the orphan bucket.
    public var isCrashpadHandler: Bool {
        URL(fileURLWithPath: commandLine.executablePath).lastPathComponent == "chrome_crashpad_handler"
    }
    public var residentMemoryBytes: UInt64 { snapshot.residentMemoryBytes }
}

/// One running browser: its main process and every helper underneath it.
///
/// Helpers are folded in rather than listed because a single browser window can
/// own dozens of them, and none of them carry the profile, headless state, or
/// debugging port that the list exists to show.
public struct ChromeInstance: Sendable {
    public let kind: ChromeBrowserKind?
    /// nil for the bucket holding helpers whose browser is gone.
    public let browser: ChromeProcess?
    public let helpers: [ChromeProcess]
    public let userDataDirectory: String?
    public let profileDirectory: String?
    public let profile: ChromeProfile?
    public let isHeadless: Bool
    public let remoteDebugging: ChromeRemoteDebugging?
    /// The port actually in use. Differs from `remoteDebugging` when the
    /// browser was told to pick its own (`--remote-debugging-port=0`) and wrote
    /// the choice into `DevToolsActivePort`; that is the case most worth
    /// reporting, and the switch alone would show it as 0.
    public let remoteDebuggingPort: Int?
    /// Another running instance asks for the same port. Both can end up
    /// listening on it, one per address family, so which one a client reaches
    /// depends on how that client resolves localhost. Probing cannot say which
    /// answered, and this is the situation the command exists to surface rather
    /// than paper over.
    public let sharesDebugPort: Bool
    public let automationFlags: [String]
    /// The process that launched the browser, when it is something other than
    /// the window server: a terminal, chromedriver, node, python.
    public let launchedBy: String?

    /// Stable across polls so SwiftUI keeps a submenu open while the list
    /// behind it is refreshed. The browser's PID identifies a running instance;
    /// the orphan bucket has no browser and is one row per browser kind.
    public var id: String { browser.map { "pid:\($0.identity.pid)" } ?? "orphans:\(kind?.rawValue ?? "unknown")" }

    public var isOrphaned: Bool { browser == nil }

    func sharingDebugPort(with contested: Set<Int>) -> ChromeInstance {
        guard let port = remoteDebuggingPort, contested.contains(port) else { return self }
        return ChromeInstance(
            kind: kind, browser: browser, helpers: helpers,
            userDataDirectory: userDataDirectory, profileDirectory: profileDirectory, profile: profile,
            isHeadless: isHeadless, remoteDebugging: remoteDebugging, remoteDebuggingPort: remoteDebuggingPort,
            sharesDebugPort: true, automationFlags: automationFlags, launchedBy: launchedBy
        )
    }
    public var allProcesses: [ChromeProcess] { (browser.map { [$0] } ?? []) + helpers }
    public var totalCPUPercent: Double { allProcesses.reduce(0) { $0 + $1.cpuPercent } }
    public var totalResidentMemoryBytes: UInt64 { allProcesses.reduce(0) { $0 &+ $1.residentMemoryBytes } }
    public var startTime: Date? { browser?.identity.startTime ?? helpers.map(\.identity.startTime).min() }

    public var displayName: String {
        guard let kind else { return "Unknown Chromium browser" }
        return kind.displayName
    }

    public var profileDescription: String {
        guard let profile else {
            guard let profileDirectory else { return "profile unknown" }
            return profileDirectory
        }
        guard let account = profile.accountName else { return profile.name }
        return "\(profile.name) <\(account)>"
    }
}

public struct ChromeInspector: Sendable {
    private let catalog: ChromeProfileCatalog
    private let fileContents: @Sendable (String) -> String?

    public init(
        catalog: ChromeProfileCatalog = .init(),
        fileContents: @escaping @Sendable (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) {
        self.catalog = catalog
        self.fileContents = fileContents
    }

    private func resolvedPort(for debugging: ChromeRemoteDebugging?, userDataDirectory: String?) -> Int? {
        guard case let .port(port) = debugging else { return nil }
        guard port == 0 else { return port }
        guard let directory = Self.readableDirectory(userDataDirectory),
              let first = fileContents(directory + "/DevToolsActivePort")?.split(separator: "\n").first
        else { return nil }
        return Int(first)
    }

    /// A directory is only read when the browser was given an absolute one.
    ///
    /// Chrome resolves a relative `--user-data-dir` against its own working
    /// directory, which is not readable for another process without a private
    /// API. Reading it here would resolve it against Killdeer's instead and
    /// report whatever happens to sit at that path, so the switch is still
    /// shown as given but nothing is read from it.
    private static func readableDirectory(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        return path
    }

    /// Samples the machine and groups the Chrome-family processes it finds.
    ///
    /// Built on `ProcessDetector.sample` so the CPU figures here are measured
    /// the same way as everywhere else in Killdeer, from two task-info
    /// snapshots a sample interval apart.
    public func sample(configuration: DetectionConfiguration = .init()) throws -> [ChromeInstance] {
        instances(from: try ProcessDetector(configuration: configuration).sample())
    }

    public func instances(from findings: [ProcessFinding]) -> [ChromeInstance] {
        let chromeProcesses = findings.compactMap { finding -> ChromeProcess? in
            let commandLine = ChromeCommandLine(
                executablePath: finding.process.executablePath,
                arguments: finding.process.arguments
            )
            // The executable path is unreadable for a process owned by another
            // user, as is the argv every other reported field comes from.
            // Falling back to the process name would put a row of unknowns in
            // the list for a browser that is not this user's to inspect or
            // signal, which is outside Killdeer's same-user scope.
            guard !commandLine.executablePath.isEmpty,
                  ChromeBrowserKind.detect(executablePath: commandLine.executablePath) != nil
            else { return nil }
            return ChromeProcess(snapshot: finding.process, commandLine: commandLine, cpuPercent: finding.cpuPercent)
        }

        let byPID = Dictionary(findings.map { ($0.process.identity.pid, $0.process) }, uniquingKeysWith: { first, _ in first })
        let browsers = chromeProcesses.filter { $0.role == .browser }
        let browsersByPID = Dictionary(browsers.map { ($0.identity.pid, $0) }, uniquingKeysWith: { first, _ in first })

        // Resolved before helpers are attached, because the crash handler is
        // matched by the directory it writes to rather than by its parent.
        let userDataDirectories = browsers.reduce(into: [pid_t: String]()) { result, browser in
            result[browser.identity.pid] = resolvedUserDataDirectory(of: browser.commandLine)
        }

        var helpersByBrowser: [pid_t: [ChromeProcess]] = [:]
        var orphansByKind: [ChromeBrowserKind?: [ChromeProcess]] = [:]
        for helper in chromeProcesses where helper.role != .browser {
            if let owner = ProcessAncestry.nearestAncestor(of: helper.snapshot, byPID: byPID, matching: {
                browsersByPID[$0.identity.pid] != nil
            }) {
                helpersByBrowser[owner.identity.pid, default: []].append(helper)
                continue
            }
            guard helper.isCrashpadHandler else {
                orphansByKind[helper.kind, default: []].append(helper)
                continue
            }
            switch Self.crashpadOwner(of: helper, browsers: browsers, userDataDirectories: userDataDirectories) {
            case let .browser(pid): helpersByBrowser[pid, default: []].append(helper)
            case .ambiguous: break
            case .none: orphansByKind[helper.kind, default: []].append(helper)
            }
        }

        let running = browsers.map { browser in
            instance(
                browser: browser,
                helpers: helpersByBrowser[browser.identity.pid] ?? [],
                userDataDirectory: userDataDirectories[browser.identity.pid],
                byPID: byPID
            )
        }
        let orphaned = orphansByKind.map { kind, helpers in
            ChromeInstance(
                kind: kind,
                browser: nil,
                helpers: helpers.sorted { $0.identity.pid < $1.identity.pid },
                userDataDirectory: nil,
                profileDirectory: nil,
                profile: nil,
                isHeadless: helpers.contains { $0.commandLine.isHeadless },
                remoteDebugging: nil,
                remoteDebuggingPort: nil,
                sharesDebugPort: false,
                automationFlags: [],
                launchedBy: nil
            )
        }

        let contestedPorts = Set(
            running.compactMap(\.remoteDebuggingPort)
                .reduce(into: [Int: Int]()) { $0[$1, default: 0] += 1 }
                .filter { $0.value > 1 }
                .keys
        )

        // Orphans last: they are the anomaly, and pushing them to the bottom
        // keeps the browsers someone is actually using at a stable position.
        return running.map { $0.sharingDebugPort(with: contestedPorts) }.sorted { ($0.displayName, $0.browser?.identity.pid ?? 0) < ($1.displayName, $1.browser?.identity.pid ?? 0) }
            + orphaned.sorted { $0.displayName < $1.displayName }
    }

    private enum CrashpadOwner {
        case browser(pid_t)
        /// Several running browsers share the installation it serves, and
        /// nothing in the process distinguishes them.
        case ambiguous
        case none
    }

    /// Places a crash handler, which the parent chain cannot.
    ///
    /// Crashpad double-forks the handler onto launchd, so its parent is PID 1
    /// while its browser is running. Treating that as orphaned would put a
    /// phantom stray row beside every healthy browser.
    ///
    /// `--database` usually names the directory of the browser that started it,
    /// but not always: a Chrome given its own `--user-data-dir` still writes
    /// crashes under the default one, so the match fails exactly when someone
    /// is running the throwaway profiles this command exists to tell apart.
    /// The installation the handler was launched from settles those, as long as
    /// only one browser is running out of it.
    private static func crashpadOwner(
        of helper: ChromeProcess,
        browsers: [ChromeProcess],
        userDataDirectories: [pid_t: String]
    ) -> CrashpadOwner {
        if let database = helper.commandLine.crashpadDatabase {
            let directory = URL(fileURLWithPath: database).deletingLastPathComponent().path
            if let owner = userDataDirectories.first(where: { $0.value == directory })?.key {
                return .browser(owner)
            }
        }
        guard let bundle = ChromeBrowserKind.appBundlePath(of: helper.commandLine.executablePath) else { return .none }
        let fromSameBundle = browsers.filter { ChromeBrowserKind.appBundlePath(of: $0.commandLine.executablePath) == bundle }
        switch fromSameBundle.count {
        case 0: return .none
        case 1: return .browser(fromSameBundle[0].identity.pid)
        // One handler serves the whole installation, so naming one of several
        // running browsers as its owner would be a guess. It is reported under
        // none of them rather than under the wrong one.
        default: return .ambiguous
        }
    }


    private func resolvedUserDataDirectory(of commandLine: ChromeCommandLine) -> String? {
        commandLine.userDataDirectory
            ?? ChromeBrowserKind.defaultUserDataDirectory(forExecutablePath: commandLine.executablePath)
    }

    private func instance(
        browser: ChromeProcess,
        helpers: [ChromeProcess],
        userDataDirectory: String?,
        byPID: [pid_t: ProcessSnapshot]
    ) -> ChromeInstance {
        let commandLine = browser.commandLine
        // Chromium reopens whatever profile it used last, so assuming "Default"
        // names the wrong one on any machine with more than one profile.
        let readableDirectory = Self.readableDirectory(userDataDirectory)
        let profileDirectory = commandLine.profileDirectory
            ?? catalog.lastUsedProfileDirectory(inUserDataDirectory: readableDirectory)
            ?? (userDataDirectory == nil ? nil : "Default")

        return ChromeInstance(
            kind: ChromeBrowserKind.detect(executablePath: commandLine.executablePath),
            browser: browser,
            helpers: helpers.sorted { $0.identity.pid < $1.identity.pid },
            userDataDirectory: userDataDirectory,
            profileDirectory: profileDirectory,
            profile: catalog.profile(userDataDirectory: readableDirectory, profileDirectory: profileDirectory),
            isHeadless: commandLine.isHeadless,
            remoteDebugging: commandLine.remoteDebugging,
            remoteDebuggingPort: resolvedPort(for: commandLine.remoteDebugging, userDataDirectory: userDataDirectory),
            sharesDebugPort: false,
            automationFlags: commandLine.automationFlags,
            launchedBy: Self.launcher(of: browser, byPID: byPID)
        )
    }

    /// Names that say nothing about who started the browser. A browser
    /// restarting itself leaves another copy of the browser in the chain, and
    /// the login session's own processes are not a launcher in any useful
    /// sense. Anything opened from the Dock or Finder is parented to launchd
    /// directly, which the walk already reports as "no ancestor".
    private static let uninformativeLaunchers: Set<String> = ["launchd", "loginwindow"]

    private static func launcher(of browser: ChromeProcess, byPID: [pid_t: ProcessSnapshot]) -> String? {
        ProcessAncestry.nearestAncestor(of: browser.snapshot, byPID: byPID) { ancestor in
            let name = ancestor.name
            return !uninformativeLaunchers.contains(name.lowercased())
                && ChromeBrowserKind.detect(executablePath: ancestor.executablePath) == nil
        }?.name
    }
}

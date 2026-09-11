import Foundation

/// The stable, machine-readable shape of `killdeer chrome --json`.
///
/// Kept as explicit `Codable` structs rather than encoding the model types, so
/// that renaming a field inside `ChromeInstance` cannot silently change the
/// published schema.
public struct ChromeReport: Codable, Sendable {
    public struct Process: Codable, Sendable {
        public let pid: pid_t
        public let parentPid: pid_t
        public let role: String
        public let name: String
        public let cpuPercent: Double
        public let residentMemoryBytes: UInt64
        public let startedAt: Date
        public let commandLine: [String]
    }

    public struct Instance: Codable, Sendable {
        public let browser: String
        public let browserKind: String?
        public let orphaned: Bool
        public let headless: Bool
        public let userDataDirectory: String?
        public let profileDirectory: String?
        public let profileName: String?
        public let profileAccount: String?
        public let remoteDebuggingPort: Int?
        public let remoteDebuggingPipe: Bool
        public let remoteDebuggingPortShared: Bool
        public let listeningOnDebuggingPort: Bool
        public let debugEndpointReachable: Bool?
        public let debugBrowserVersion: String?
        public let webSocketDebuggerUrl: String?
        public let automationFlags: [String]
        public let launchedBy: String?
        public let startedAt: Date?
        public let helperCount: Int
        public let totalCpuPercent: Double
        public let totalResidentMemoryBytes: UInt64
        public let processes: [Process]
    }

    public let generatedAt: Date
    public let instances: [Instance]
}

/// `JSONEncoder` drops keys whose value is nil, which would make the shape of
/// each instance depend on how that browser happened to be launched. A consumer
/// can then not tell "this browser has no debugging port" from "this version of
/// Killdeer stopped reporting ports". Every optional is written as an explicit
/// null instead.
private extension KeyedEncodingContainer {
    mutating func encodeAlways<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}

extension ChromeReport.Instance {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(browser, forKey: .browser)
        try container.encodeAlways(browserKind, forKey: .browserKind)
        try container.encode(orphaned, forKey: .orphaned)
        try container.encode(headless, forKey: .headless)
        try container.encodeAlways(userDataDirectory, forKey: .userDataDirectory)
        try container.encodeAlways(profileDirectory, forKey: .profileDirectory)
        try container.encodeAlways(profileName, forKey: .profileName)
        try container.encodeAlways(profileAccount, forKey: .profileAccount)
        try container.encodeAlways(remoteDebuggingPort, forKey: .remoteDebuggingPort)
        try container.encode(remoteDebuggingPipe, forKey: .remoteDebuggingPipe)
        try container.encode(remoteDebuggingPortShared, forKey: .remoteDebuggingPortShared)
        try container.encode(listeningOnDebuggingPort, forKey: .listeningOnDebuggingPort)
        try container.encodeAlways(debugEndpointReachable, forKey: .debugEndpointReachable)
        try container.encodeAlways(debugBrowserVersion, forKey: .debugBrowserVersion)
        try container.encodeAlways(webSocketDebuggerUrl, forKey: .webSocketDebuggerUrl)
        try container.encode(automationFlags, forKey: .automationFlags)
        try container.encodeAlways(launchedBy, forKey: .launchedBy)
        try container.encodeAlways(startedAt, forKey: .startedAt)
        try container.encode(helperCount, forKey: .helperCount)
        try container.encode(totalCpuPercent, forKey: .totalCpuPercent)
        try container.encode(totalResidentMemoryBytes, forKey: .totalResidentMemoryBytes)
        try container.encode(processes, forKey: .processes)
    }
}

extension ChromeReport {
    /// - Parameter probes: probe results keyed by the resolved port. Absent when
    ///   `--probe` was not asked for, which is why reachability is a tri-state:
    ///   nil means "not checked", not "unreachable".
    public init(
        instances: [ChromeInstance],
        probes: [Int: ChromeDebugTarget?] = [:],
        generatedAt: Date = Date()
    ) {
        self.generatedAt = generatedAt
        self.instances = instances.map { instance in
            let port = instance.remoteDebuggingPort
            // Left unchecked unless this browser holds the port outright.
            // Something may answer on it, but saying it was this instance when
            // the bind failed or another holds it too would be a guess.
            let probe = instance.ownsDebugEndpoint ? port.flatMap { probes[$0] } : nil
            return Instance(
                browser: instance.displayName,
                browserKind: instance.kind?.rawValue,
                orphaned: instance.isOrphaned,
                headless: instance.isHeadless,
                userDataDirectory: instance.userDataDirectory,
                profileDirectory: instance.profileDirectory,
                profileName: instance.profile?.name,
                profileAccount: instance.profile?.accountName,
                remoteDebuggingPort: port,
                remoteDebuggingPipe: instance.remoteDebugging == .pipe,
                remoteDebuggingPortShared: instance.sharesDebugPort,
                listeningOnDebuggingPort: instance.isListeningOnDebugPort,
                debugEndpointReachable: probe.map { $0 != nil },
                debugBrowserVersion: probe.flatMap { $0?.browser },
                webSocketDebuggerUrl: probe.flatMap { $0?.webSocketDebuggerURL },
                automationFlags: instance.automationFlags,
                launchedBy: instance.launchedBy,
                startedAt: instance.startTime,
                helperCount: instance.helpers.count,
                totalCpuPercent: instance.totalCPUPercent,
                totalResidentMemoryBytes: instance.totalResidentMemoryBytes,
                processes: instance.allProcesses.map { process in
                    Process(
                        pid: process.identity.pid,
                        parentPid: process.snapshot.parentPID,
                        role: process.role.displayName,
                        name: process.snapshot.name,
                        cpuPercent: process.cpuPercent,
                        residentMemoryBytes: process.residentMemoryBytes,
                        startedAt: process.identity.startTime,
                        commandLine: process.snapshot.arguments
                    )
                }
            )
        }
    }
}

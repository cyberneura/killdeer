import Foundation

public struct ProcessIdentity: Hashable, Sendable {
    public let pid: pid_t
    public let startTime: Date

    public init(pid: pid_t, startTime: Date) {
        self.pid = pid
        self.startTime = startTime
    }
}

public struct ProcessSnapshot: Sendable {
    public let identity: ProcessIdentity
    public let parentPID: pid_t
    public let name: String
    public let arguments: [String]
    public let totalCPUTimeNanoseconds: UInt64

    public init(
        identity: ProcessIdentity,
        parentPID: pid_t,
        name: String,
        arguments: [String],
        totalCPUTimeNanoseconds: UInt64
    ) {
        self.identity = identity
        self.parentPID = parentPID
        self.name = name
        self.arguments = arguments
        self.totalCPUTimeNanoseconds = totalCPUTimeNanoseconds
    }
}

public struct ProcessFinding: Sendable {
    public let process: ProcessSnapshot
    public let cpuPercent: Double
    public let isOrphanChromeHelper: Bool
    public let score: Int
    public let reasons: [String]

    public var isRunaway: Bool { score >= 50 }
}

public struct DetectionConfiguration: Sendable {
    public var cpuThresholdPercent: Double
    public var sampleInterval: TimeInterval

    public init(cpuThresholdPercent: Double = 80, sampleInterval: TimeInterval = 1) {
        self.cpuThresholdPercent = cpuThresholdPercent
        self.sampleInterval = sampleInterval
    }
}

public enum KilldeerError: Error, LocalizedError {
    case sysctlFailed(String, Int32)
    case processDisappeared(pid_t)
    case processRecycled(pid_t)
    case signalFailed(pid_t, Int32, Int32)

    public var errorDescription: String? {
        switch self {
        case let .sysctlFailed(operation, code):
            return "\(operation) failed: \(String(cString: strerror(code)))"
        case let .processDisappeared(pid): return "process \(pid) no longer exists"
        case let .processRecycled(pid): return "PID \(pid) was recycled; refusing to signal it"
        case let .signalFailed(pid, signal, code):
            return "signal \(signal) to PID \(pid) failed: \(String(cString: strerror(code)))"
        }
    }
}

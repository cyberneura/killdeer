import Darwin
import Foundation

public struct ProcessTerminator: Sendable {
    public let gracePeriod: TimeInterval
    private let enumerator: ProcessEnumerator

    public init(gracePeriod: TimeInterval = 3, enumerator: ProcessEnumerator = .init()) {
        self.gracePeriod = gracePeriod
        self.enumerator = enumerator
    }

    public func terminate(_ identity: ProcessIdentity) throws {
        try verify(identity)
        guard Darwin.kill(identity.pid, SIGTERM) == 0 else {
            if errno == ESRCH { return }
            throw KilldeerError.signalFailed(identity.pid, SIGTERM, errno)
        }

        let deadline = Date().addingTimeInterval(gracePeriod)
        while Date() < deadline {
            if Darwin.kill(identity.pid, 0) != 0, errno == ESRCH { return }
            Thread.sleep(forTimeInterval: 0.1)
        }

        try verify(identity)
        guard Darwin.kill(identity.pid, SIGKILL) == 0 else {
            if errno == ESRCH { return }
            throw KilldeerError.signalFailed(identity.pid, SIGKILL, errno)
        }
    }

    private func verify(_ expected: ProcessIdentity) throws {
        guard let actual = enumerator.identity(for: expected.pid) else {
            throw KilldeerError.processDisappeared(expected.pid)
        }
        guard abs(actual.startTime.timeIntervalSince(expected.startTime)) < 0.000_001 else {
            throw KilldeerError.processRecycled(expected.pid)
        }
    }
}

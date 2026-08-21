import XCTest
@testable import KilldeerCore

final class KilldeerCoreTests: XCTestCase {
    func testHighCPUIsRunaway() {
        let process = snapshot(pid: 10, parent: 1, name: "worker", cpu: 900_000_000)
        let previous = snapshot(pid: 10, parent: 1, name: "worker", cpu: 0)
        let result = ProcessDetector().findings(previous: [previous], current: [process], elapsed: 1)
        XCTAssertTrue(result[0].isRunaway)
        XCTAssertEqual(result[0].cpuPercent, 90, accuracy: 0.01)
    }

    func testDisconnectedChromeHelperIsDetectedButNotRunawayWhenIdle() {
        let helper = snapshot(pid: 20, parent: 999, name: "Google Chrome Helper (Renderer)", cpu: 0)
        let result = ProcessDetector().findings(previous: [helper], current: [helper], elapsed: 1)
        XCTAssertTrue(result[0].isOrphanChromeHelper)
        XCTAssertFalse(result[0].isRunaway)
    }

    func testConnectedChromeHelperIsNotOrphan() {
        let browser = snapshot(pid: 30, parent: 1, name: "Google Chrome", cpu: 0, args: ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"])
        let helper = snapshot(pid: 31, parent: 30, name: "Google Chrome Helper (Renderer)", cpu: 0, args: ["helper", "--type=renderer"])
        let result = ProcessDetector().findings(previous: [browser, helper], current: [browser, helper], elapsed: 1)
        XCTAssertFalse(result.first { $0.process.identity.pid == 31 }!.isOrphanChromeHelper)
    }

    private func snapshot(pid: pid_t, parent: pid_t, name: String, cpu: UInt64, args: [String] = []) -> ProcessSnapshot {
        ProcessSnapshot(
            identity: ProcessIdentity(pid: pid, startTime: Date(timeIntervalSince1970: 100)),
            parentPID: parent, name: name, arguments: args, totalCPUTimeNanoseconds: cpu
        )
    }
}

import XCTest
@testable import KilldeerCore

final class CPUMeterTests: XCTestCase {
    func testNoReadingDrawsAnEmptyMeter() {
        XCTAssertEqual(CPUMeter.level(forPercent: nil), 0)
    }

    func testIdleDrawsAnEmptyMeter() {
        XCTAssertEqual(CPUMeter.level(forPercent: 0), 0)
    }

    func testAnyLoadShowsAtLeastOneStep() {
        // 3% rounds to zero steps, but an empty meter beside "CPU 3.0%" in the
        // menu would look broken.
        XCTAssertEqual(CPUMeter.level(forPercent: 3), 1)
    }

    func testRoundsToTheNearestStep() {
        XCTAssertEqual(CPUMeter.level(forPercent: 44), 4)
        XCTAssertEqual(CPUMeter.level(forPercent: 46), 5)
    }

    func testFullLoadFillsTheMeter() {
        XCTAssertEqual(CPUMeter.level(forPercent: 100), CPUMeter.steps)
    }

    func testOutOfRangeValuesAreClamped() {
        XCTAssertEqual(CPUMeter.level(forPercent: 250), CPUMeter.steps)
        XCTAssertEqual(CPUMeter.level(forPercent: -5), 0)
        XCTAssertEqual(CPUMeter.level(forPercent: .nan), 0)
    }
}

final class TopProcessesTests: XCTestCase {
    func testOrdersByCPUAndKeepsTheLimit() {
        // Arrange
        let findings = [
            finding(pid: 1, cpu: 12),
            finding(pid: 2, cpu: 340),
            finding(pid: 3, cpu: 55),
            finding(pid: 4, cpu: 80),
        ]

        // Act
        let result = TopProcesses.select(from: findings, limit: 3)

        // Assert
        XCTAssertEqual(result.map(\.process.identity.pid), [2, 4, 3])
    }

    func testIncludesProcessesThatAreNotRunaways() {
        // The point of the list: a busy compiler below the runaway threshold
        // still belongs in it.
        // Arrange
        let findings = [finding(pid: 7, cpu: 35)]

        // Act
        let result = TopProcesses.select(from: findings)

        // Assert
        XCTAssertFalse(findings[0].isRunaway)
        XCTAssertEqual(result.map(\.process.identity.pid), [7])
    }

    func testLeavesOutIdleProcesses() {
        // Arrange
        let findings = [finding(pid: 1, cpu: 0), finding(pid: 2, cpu: 0.4), finding(pid: 3, cpu: 1)]

        // Act
        let result = TopProcesses.select(from: findings)

        // Assert
        XCTAssertEqual(result.map(\.process.identity.pid), [3])
    }

    func testBreaksTiesByPID() {
        // Arrange
        let findings = [finding(pid: 9, cpu: 20), finding(pid: 4, cpu: 20)]

        // Act
        let result = TopProcesses.select(from: findings)

        // Assert
        XCTAssertEqual(result.map(\.process.identity.pid), [4, 9])
    }

    func testZeroLimitReturnsNothing() {
        XCTAssertTrue(TopProcesses.select(from: [finding(pid: 1, cpu: 90)], limit: 0).isEmpty)
    }

    private func finding(pid: pid_t, cpu: Double) -> ProcessFinding {
        ProcessFinding(
            process: ProcessSnapshot(
                identity: ProcessIdentity(pid: pid, startTime: Date(timeIntervalSince1970: 100)),
                parentPID: 1, name: "process \(pid)", arguments: [], totalCPUTimeNanoseconds: 0
            ),
            cpuPercent: cpu, isOrphanChromeHelper: false, score: 0, reasons: []
        )
    }
}

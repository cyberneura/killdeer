import XCTest
@testable import KilldeerCore

final class SystemStrainTests: XCTestCase {
    func testThrottlingStartsAtSerious() {
        XCTAssertFalse(ThermalPressure.nominal.isThrottling)
        XCTAssertFalse(ThermalPressure.fair.isThrottling)
        XCTAssertTrue(ThermalPressure.serious.isThrottling)
        XCTAssertTrue(ThermalPressure.critical.isThrottling)
    }

    func testThermalPressureFollowsFoundationState() {
        XCTAssertEqual(ThermalPressure(.nominal), .nominal)
        XCTAssertEqual(ThermalPressure(.fair), .fair)
        XCTAssertEqual(ThermalPressure(.serious), .serious)
        XCTAssertEqual(ThermalPressure(.critical), .critical)
    }

    func testOneFullReadingIsNotPegged() {
        var detector = PeggedCPUDetector()
        XCTAssertFalse(detector.update(cpuPercent: 100, interval: 10))
        XCTAssertFalse(detector.update(cpuPercent: 100, interval: 10))
        XCTAssertTrue(detector.update(cpuPercent: 100, interval: 10))
    }

    func testADipRestartsTheRun() {
        var detector = PeggedCPUDetector()
        _ = detector.update(cpuPercent: 99, interval: 10)
        _ = detector.update(cpuPercent: 99, interval: 10)
        XCTAssertFalse(detector.update(cpuPercent: 94.9, interval: 10))
        XCTAssertFalse(detector.update(cpuPercent: 99, interval: 10))
        XCTAssertFalse(detector.update(cpuPercent: 99, interval: 10))
        XCTAssertTrue(detector.update(cpuPercent: 99, interval: 10))
    }

    func testPeggedHoldsUntilClearlyBelowTheLine() {
        var detector = PeggedCPUDetector(sustain: 10)
        XCTAssertTrue(detector.update(cpuPercent: 97, interval: 10))
        XCTAssertTrue(detector.update(cpuPercent: 90, interval: 10))
        XCTAssertTrue(detector.update(cpuPercent: 85, interval: 10))
        XCTAssertFalse(detector.update(cpuPercent: 84.9, interval: 10))
        // The run starts from nothing again after a release.
        var slow = PeggedCPUDetector()
        for _ in 0..<3 { _ = slow.update(cpuPercent: 100, interval: 10) }
        _ = slow.update(cpuPercent: 10, interval: 10)
        XCTAssertFalse(slow.update(cpuPercent: 100, interval: 10))
    }

    func testALongPollPegsOnItsFirstReading() {
        var detector = PeggedCPUDetector()
        XCTAssertTrue(detector.update(cpuPercent: 96, interval: 60))
    }

    func testAFailedSampleRestartsARunButKeepsAWarning() {
        var detector = PeggedCPUDetector()
        _ = detector.update(cpuPercent: 100, interval: 10)
        _ = detector.update(cpuPercent: 100, interval: 10)
        XCTAssertFalse(detector.update(cpuPercent: nil, interval: 10))
        XCTAssertFalse(detector.update(cpuPercent: 100, interval: 10))
        XCTAssertFalse(detector.update(cpuPercent: 100, interval: 10))
        XCTAssertFalse(detector.update(cpuPercent: .nan, interval: 10))
        for _ in 0..<2 { XCTAssertFalse(detector.update(cpuPercent: 100, interval: 10)) }
        XCTAssertTrue(detector.update(cpuPercent: 100, interval: 10))
        XCTAssertTrue(detector.update(cpuPercent: nil, interval: 10))
    }

    func testTheRunCountsTheTimeThatPassed() {
        var detector = PeggedCPUDetector()
        XCTAssertFalse(detector.update(cpuPercent: 100, interval: 14.9))
        XCTAssertFalse(detector.update(cpuPercent: 100, interval: 14.9))
        XCTAssertTrue(detector.update(cpuPercent: 100, interval: 0.2))
    }

    func testMenuText() {
        XCTAssertNil(SystemStrain().menuText)
        XCTAssertNil(SystemStrain(thermal: .fair).menuText)
        XCTAssertEqual(SystemStrain(cpuPegged: true).menuText, "⚠ CPU stuck at full load")
        XCTAssertEqual(SystemStrain(thermal: .serious).menuText, "⚠ Thermal throttling")
        XCTAssertEqual(
            SystemStrain(cpuPegged: true, thermal: .critical).menuText,
            "⚠ CPU stuck at full load · Thermal throttling (critical)"
        )
    }

    func testOnlyAConditionThatHasJustBegunIsAnnounced() {
        let calm = SystemStrain()
        let pegged = SystemStrain(cpuPegged: true)
        let both = SystemStrain(cpuPegged: true, thermal: .serious)
        XCTAssertEqual(pegged.notifications(since: calm), [.cpuPegged])
        XCTAssertEqual(both.notifications(since: pegged), [.thermalThrottling])
        XCTAssertEqual(both.notifications(since: calm), [.cpuPegged, .thermalThrottling])
        XCTAssertEqual(both.notifications(since: both), [])
        XCTAssertEqual(calm.notifications(since: both), [])
        // Getting worse while already throttled is the same condition.
        XCTAssertEqual(
            SystemStrain(thermal: .critical).notifications(since: SystemStrain(thermal: .serious)), []
        )
    }
}

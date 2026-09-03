import XCTest
@testable import KilldeerCore

final class TemperatureSelectionTests: XCTestCase {
    func testPrefersTheHottestDieSensor() {
        // Arrange
        let readings = [
            SensorReading(name: "PMU tdie1", celsius: 61.5),
            SensorReading(name: "PMU tdie2", celsius: 63.4),
            SensorReading(name: "NAND CH0 temp", celsius: 47.0),
        ]

        // Act
        let result = TemperatureSelection.representative(from: readings)

        // Assert
        XCTAssertEqual(result, 63.4)
    }

    func testIgnoresDisconnectedSensorsReportingBelowFreezing() {
        // A MacBook reports about -1.9 from several tdev sensors. Left in, they
        // are picked as "the machine" by any rule that takes a minimum, and they
        // drag an average down.
        // Arrange
        let readings = [
            SensorReading(name: "PMU tdev1", celsius: -1.88),
            SensorReading(name: "PMU tdie1", celsius: 60.0),
        ]

        // Act
        let result = TemperatureSelection.representative(from: readings)

        // Assert
        XCTAssertEqual(result, 60.0)
    }

    func testFallsBackToTheHottestSensorWhenNoDieSensorExists() {
        // Sensor names are machine specific; an Intel Mac has no tdie at all.
        // Arrange
        let readings = [
            SensorReading(name: "gas gauge battery", celsius: 37.1),
            SensorReading(name: "NAND CH0 temp", celsius: 47.0),
        ]

        // Act
        let result = TemperatureSelection.representative(from: readings)

        // Assert
        XCTAssertEqual(result, 47.0)
    }

    func testReturnsNothingWhenEverySensorIsImplausible() {
        // Arrange
        let readings = [
            SensorReading(name: "PMU tdev1", celsius: -1.88),
            SensorReading(name: "PMU tdev2", celsius: 0),
            SensorReading(name: "broken", celsius: 3000),
        ]

        // Act
        let result = TemperatureSelection.representative(from: readings)

        // Assert
        XCTAssertNil(result)
    }

    func testReturnsNothingWhenTheMachineOffersNoSensors() {
        // Arrange
        let readings: [SensorReading] = []

        // Act
        let result = TemperatureSelection.representative(from: readings)

        // Assert
        XCTAssertNil(result)
    }
}

final class CPULoadTests: XCTestCase {
    func testComputesPercentageFromTheTickDelta() {
        // Arrange
        let first = CPUTicks(busy: 1_000, total: 4_000)
        let second = CPUTicks(busy: 1_250, total: 5_000)

        // Act
        let result = CPULoad.percentage(from: first, to: second)

        // Assert
        XCTAssertEqual(result ?? -1, 25, accuracy: 0.001)
    }

    func testReturnsNothingWhenNoTimePassed() {
        // Two samples taken back to back can land on the same tick counts.
        // Dividing Double by that delta yields a NaN rather than trapping, and
        // a NaN reaches the menu as "CPU nan%".
        // Arrange
        let ticks = CPUTicks(busy: 1_000, total: 4_000)

        // Act
        let result = CPULoad.percentage(from: ticks, to: ticks)

        // Assert
        XCTAssertNil(result)
    }

    func testReturnsNothingWhenTheCountersWentBackwards() {
        // The counters are monotonic, but a sleep/wake can still hand back a
        // smaller second sample, and a negative percentage in the menu is worse
        // than no percentage.
        // Arrange
        let first = CPUTicks(busy: 2_000, total: 5_000)
        let second = CPUTicks(busy: 1_000, total: 6_000)

        // Act
        let result = CPULoad.percentage(from: first, to: second)

        // Assert
        XCTAssertNil(result)
    }

    func testClampsToOneHundred() {
        // Arrange
        let first = CPUTicks(busy: 0, total: 0)
        let second = CPUTicks(busy: 5_000, total: 1_000)

        // Act
        let result = CPULoad.percentage(from: first, to: second)

        // Assert
        XCTAssertEqual(result ?? -1, 100, accuracy: 0.001)
    }

    func testReadsTheKernelCounters() {
        // Arrange, Act
        let sample = CPULoad.sample()

        // Assert
        XCTAssertNotNil(sample)
        XCTAssertGreaterThan(sample?.total ?? 0, 0)
        XCTAssertLessThanOrEqual(sample?.busy ?? .infinity, sample?.total ?? 0)
    }
}

final class TemperatureSensorSelectionTests: XCTestCase {
    func testReadsOnlyTheDieSensorsWhenTheMachineHasThem() {
        // Arrange
        let names = ["PMU tdie1", "gas gauge battery", "PMU2 tdie4", "NAND CH0 temp"]

        // Act
        let result = TemperatureSelection.sensorsToRead(named: names)

        // Assert
        XCTAssertEqual(result, [0, 2])
    }

    func testReadsEverySensorWhenTheMachineHasNoDieSensor() {
        // Arrange
        let names = ["gas gauge battery", "NAND CH0 temp"]

        // Act
        let result = TemperatureSelection.sensorsToRead(named: names)

        // Assert
        XCTAssertEqual(result, [0, 1])
    }

    func testReadsNothingWhenTheMachineOffersNoSensors() {
        // Arrange
        let names: [String] = []

        // Act
        let result = TemperatureSelection.sensorsToRead(named: names)

        // Assert
        XCTAssertTrue(result.isEmpty)
    }

    func testNarrowingDropsTheFallbackOnceDieSensorsExist() {
        // The one place narrowing changes the answer, pinned so that it stays a
        // decision rather than becoming a surprise: with every die sensor out of
        // range there is no longer a battery reading left to fall back to.
        // Arrange
        let names = ["PMU tdie1", "gas gauge battery"]
        let allReadings = [
            SensorReading(name: "PMU tdie1", celsius: -1.9),
            SensorReading(name: "gas gauge battery", celsius: 37.1),
        ]

        // Act
        let kept = TemperatureSelection.sensorsToRead(named: names)
        let narrowed = TemperatureSelection.representative(from: kept.map { allReadings[$0] })
        let unnarrowed = TemperatureSelection.representative(from: allReadings)

        // Assert
        XCTAssertNil(narrowed)
        XCTAssertEqual(unnarrowed, 37.1)
    }
}

final class TemperatureReaderTests: XCTestCase {
    func testSurvivesRepeatedReads() {
        // The crash this guards against was a client released at the end of
        // init, leaving the service handles pointing at freed memory. Put the
        // bug back and this test dies on the first read, measured; the second
        // is there because nothing guarantees that on other hardware.
        // Arrange
        let reader = TemperatureReader()

        // Act
        let first = reader.readings()
        let second = reader.readings()

        // Assert
        // Only one direction holds. A machine with no sensors reads nothing,
        // but a machine with sensors can still read nothing: CopyEvent fails
        // per sensor, and 22 of one machine's 23 non-die sensors answered on a
        // measured run. Asserting a count, or equal counts, would be a test
        // that fails on hardware rather than on a regression.
        if !reader.isAvailable {
            XCTAssertTrue(first.isEmpty)
            XCTAssertTrue(second.isEmpty)
        }
    }

    func testReadsConcurrentlyWithoutTripping() {
        // A smoke detector for crashes and deadlocks, not evidence that the lock
        // is needed: with the lock removed, 3840 concurrent CopyEvent calls
        // came through intact, so this path looks thread safe on IOKit's side
        // already. The lock is there because @unchecked Sendable promises a
        // caller can do this, and a promise should not rest on a measurement of
        // one macOS version. On a CI runner there are no sensors, so this test
        // only proves the empty path does not hang.
        // Arrange
        let reader = TemperatureReader()
        let group = DispatchGroup()

        // Act
        for _ in 0..<8 {
            DispatchQueue.global().async(group: group) { _ = reader.readings() }
        }
        let outcome = group.wait(timeout: .now() + 30)

        // Assert
        XCTAssertEqual(outcome, .success)
    }
}

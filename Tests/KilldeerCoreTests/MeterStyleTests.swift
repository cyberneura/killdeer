import XCTest
@testable import KilldeerCore

final class MeterStyleTests: XCTestCase {
    func testEveryStyleRoundTripsThroughItsStoredValue() {
        for style in MeterStyle.allCases {
            XCTAssertEqual(MeterStyle(rawValue: style.rawValue), style)
        }
        XCTAssertEqual(MeterStyle.allCases.count, 8)
        XCTAssertEqual(MeterStyle.default, .birdWithGauge)
    }

    func testOnlyTheFlappingBirdIsAnimated() {
        XCTAssertEqual(MeterStyle.allCases.filter(\.isAnimated), [.flappingBird])
    }

    func testTheCoreStylesAreTheOnesDrawnFromCores() {
        XCTAssertEqual(MeterStyle.allCases.filter(\.usesCores), [.coreBars, .coreHeatmap])
    }
}

final class FlapRateTests: XCTestCase {
    func testAnIdleMachineKeepsTheBirdStill() {
        XCTAssertNil(FlapRate.interval(forLevel: 0))
        XCTAssertNil(FlapRate.interval(forLevel: -3))
    }

    func testTheBeatQuickensWithTheLoad() {
        // Arrange / Act
        let slow = FlapRate.interval(forLevel: 1)
        let middle = FlapRate.interval(forLevel: 5)
        let fast = FlapRate.interval(forLevel: CPUMeter.steps)

        // Assert
        XCTAssertEqual(slow ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(middle ?? 0, 0.16, accuracy: 1e-9)
        XCTAssertLessThan(fast ?? 1, middle ?? 0)
    }

    func testTheBeatIsNeverFasterThanTheCap() {
        XCTAssertEqual(FlapRate.interval(forLevel: CPUMeter.steps) ?? 0, 0.08, accuracy: 1e-9)
        XCTAssertEqual(FlapRate.interval(forLevel: 500) ?? 0, 0.08, accuracy: 1e-9)
    }
}

final class WeatherKindTests: XCTestCase {
    func testClimbsFromSunToThunder() {
        XCTAssertEqual(WeatherKind.forLevel(0), .sun)
        XCTAssertEqual(WeatherKind.forLevel(1), .sun)
        XCTAssertEqual(WeatherKind.forLevel(2), .sunBehindCloud)
        XCTAssertEqual(WeatherKind.forLevel(3), .sunBehindCloud)
        XCTAssertEqual(WeatherKind.forLevel(4), .cloud)
        XCTAssertEqual(WeatherKind.forLevel(5), .cloud)
        XCTAssertEqual(WeatherKind.forLevel(6), .rain)
        XCTAssertEqual(WeatherKind.forLevel(8), .rain)
        XCTAssertEqual(WeatherKind.forLevel(9), .thunder)
        XCTAssertEqual(WeatherKind.forLevel(CPUMeter.steps), .thunder)
    }

    func testOutOfRangeLevelsStayAtTheEnds() {
        XCTAssertEqual(WeatherKind.forLevel(-1), .sun)
        XCTAssertEqual(WeatherKind.forLevel(99), .thunder)
    }
}

final class CoffeeCupTests: XCTestCase {
    func testAnEmptyCupHasNoSteam() {
        XCTAssertEqual(CoffeeCup.forLevel(0), CoffeeCup(steamLines: 0, overflowing: false))
        XCTAssertEqual(CoffeeCup.fill(forLevel: 0), 0)
    }

    func testSteamRisesWithTheLoad() {
        XCTAssertEqual(CoffeeCup.forLevel(1).steamLines, 1)
        XCTAssertEqual(CoffeeCup.forLevel(3).steamLines, 1)
        XCTAssertEqual(CoffeeCup.forLevel(4).steamLines, 2)
        XCTAssertEqual(CoffeeCup.forLevel(6).steamLines, 2)
        XCTAssertEqual(CoffeeCup.forLevel(7).steamLines, 3)
        XCTAssertEqual(CoffeeCup.fill(forLevel: 5), 0.5)
    }

    func testOnlyFullLoadSpillsOver() {
        XCTAssertFalse(CoffeeCup.forLevel(CPUMeter.steps - 1).overflowing)
        XCTAssertEqual(CoffeeCup.forLevel(CPUMeter.steps), CoffeeCup(steamLines: 3, overflowing: true))
        XCTAssertEqual(CoffeeCup.forLevel(42), CoffeeCup(steamLines: 3, overflowing: true))
        XCTAssertEqual(CoffeeCup.fill(forLevel: 42), 1)
    }
}

final class MoonPhaseTests: XCTestCase {
    func testWaxesFromNewToFull() {
        XCTAssertEqual(MoonPhase.terminator(forLevel: 0), 1)
        XCTAssertEqual(MoonPhase.terminator(forLevel: CPUMeter.steps / 2), 0, accuracy: 1e-9)
        XCTAssertEqual(MoonPhase.terminator(forLevel: CPUMeter.steps), -1)
        XCTAssertEqual(MoonPhase.terminator(forLevel: 99), -1)
        XCTAssertEqual(MoonPhase.terminator(forLevel: -1), 1)
    }

    func testTheTerminatorMovesOneWayOnly() {
        let positions = (0...CPUMeter.steps).map { MoonPhase.terminator(forLevel: $0) }
        XCTAssertEqual(positions, positions.sorted(by: >))
    }
}

final class RingGaugeTests: XCTestCase {
    func testStartsAtSevenOClockAndSweepsRoundToFive() {
        XCTAssertEqual(RingGauge.startDegrees, 210)
        XCTAssertEqual(RingGauge.sweepDegrees, 300)
        XCTAssertEqual(RingGauge.sweep(forLevel: 0), 0)
        XCTAssertEqual(RingGauge.sweep(forLevel: CPUMeter.steps / 2), 150)
        XCTAssertEqual(RingGauge.sweep(forLevel: CPUMeter.steps), 300)
        XCTAssertEqual(RingGauge.sweep(forLevel: 50), 300)
    }
}

final class CoreMeterTests: XCTestCase {
    func testOneLevelPerCore() {
        XCTAssertEqual(CoreMeter.levels(forPercents: [0, 3, 50, 100]), [0, 1, 5, 10])
    }

    func testNoReadingsGiveNoBars() {
        XCTAssertEqual(CoreMeter.levels(forPercents: []), [])
        XCTAssertEqual(CoreMeter.levels(forPercents: [50], maxBars: 0), [])
    }

    func testMoreCoresThanBarsAreAveragedInGroups() {
        // Arrange: 32 cores, in pairs of (0, 100).
        let percents = (0..<32).map { $0 % 2 == 0 ? 0.0 : 100.0 }

        // Act
        let levels = CoreMeter.levels(forPercents: percents)

        // Assert
        XCTAssertEqual(levels.count, CoreMeter.maxBars)
        XCTAssertEqual(levels, Array(repeating: 5, count: CoreMeter.maxBars))
    }

    func testAnUnevenGroupingKeepsEveryCore() {
        // Arrange: 20 cores over 16 bars go in groups of two, which is ten
        // bars rather than sixteen; the bars stand for equal groups.
        let percents = Array(repeating: 100.0, count: 20)

        // Act
        let levels = CoreMeter.levels(forPercents: percents)

        // Assert
        XCTAssertEqual(levels, Array(repeating: 10, count: 10))
    }

    func testAGroupWithNoFiniteReadingDrawsEmpty() {
        XCTAssertEqual(CoreMeter.levels(forPercents: [.nan, 40, .infinity]), [0, 4, 0])
    }
}

final class HeatmapGridTests: XCTestCase {
    func testLaysTilesOutInUpToThreeRows() {
        XCTAssertTrue(HeatmapGrid.layout(count: 1) == (rows: 1, columns: 1))
        XCTAssertTrue(HeatmapGrid.layout(count: 4) == (rows: 1, columns: 4))
        XCTAssertTrue(HeatmapGrid.layout(count: 8) == (rows: 2, columns: 4))
        XCTAssertTrue(HeatmapGrid.layout(count: 10) == (rows: 3, columns: 4))
        XCTAssertTrue(HeatmapGrid.layout(count: 16) == (rows: 3, columns: 6))
        XCTAssertTrue(HeatmapGrid.layout(count: 0) == (rows: 1, columns: 1))
    }

    func testEveryTileHasAPlace() {
        for count in 1...64 {
            let grid = HeatmapGrid.layout(count: count)
            XCTAssertGreaterThanOrEqual(grid.rows * grid.columns, count, "\(count) tiles")
            XCTAssertLessThanOrEqual(grid.rows, 3, "\(count) tiles")
        }
    }
}

final class CorePercentagesTests: XCTestCase {
    func testOnePercentagePerCore() {
        // Arrange
        let first = [CPUTicks(busy: 100, total: 1_000), CPUTicks(busy: 50, total: 1_000)]
        let second = [CPUTicks(busy: 200, total: 1_100), CPUTicks(busy: 60, total: 1_100)]

        // Act
        let result = CPULoad.corePercentages(from: first, to: second)

        // Assert
        XCTAssertEqual(result, [100, 10])
    }

    func testACoreThatSawNoTimePassReadsAsIdle() {
        // Arrange
        let first = [CPUTicks(busy: 100, total: 1_000), CPUTicks(busy: 50, total: 1_000)]
        let second = [CPUTicks(busy: 150, total: 1_100), CPUTicks(busy: 50, total: 1_000)]

        // Act
        let result = CPULoad.corePercentages(from: first, to: second)

        // Assert
        XCTAssertEqual(result, [50, 0])
    }

    func testSnapshotsOfDifferentCoresDoNotCompare() {
        // Arrange
        let first = [CPUTicks(busy: 1, total: 2)]
        let second = [CPUTicks(busy: 2, total: 4), CPUTicks(busy: 2, total: 4)]

        // Act / Assert
        XCTAssertNil(CPULoad.corePercentages(from: first, to: second))
        XCTAssertNil(CPULoad.corePercentages(from: [], to: []))
    }
}

import XCTest
@testable import KilldeerCore

final class MeterStyleTests: XCTestCase {
    func testEveryStyleRoundTripsThroughItsStoredValue() {
        for style in MeterStyle.allCases {
            XCTAssertEqual(MeterStyle(rawValue: style.rawValue), style)
        }
        XCTAssertEqual(MeterStyle.allCases.count, 9)
        XCTAssertEqual(MeterStyle.default, .birdWithGauge)
    }

    func testOnlyTheFlappingBirdIsAnimated() {
        XCTAssertEqual(MeterStyle.allCases.filter(\.isAnimated), [.flappingBird])
    }

    func testTheCoreStylesAreTheOnesDrawnFromCores() {
        XCTAssertEqual(MeterStyle.allCases.filter(\.usesCores), [.coreBars, .coreHeatmap])
    }

    func testOnlyTheHistoryGraphIsDrawnFromHistory() {
        XCTAssertEqual(MeterStyle.allCases.filter(\.usesHistory), [.historyGraph])
    }
}

final class TemperatureMeterTests: XCTestCase {
    func testSpansThirtyToAHundredInTenSteps() {
        XCTAssertEqual(TemperatureMeter.level(forCelsius: 30), 0)
        XCTAssertEqual(TemperatureMeter.level(forCelsius: 65), 5)
        XCTAssertEqual(TemperatureMeter.level(forCelsius: 100), CPUMeter.steps)
    }

    func testOutOfRangeIsHeldAndNoReadingIsNil() {
        XCTAssertEqual(TemperatureMeter.level(forCelsius: -2), 0)
        XCTAssertEqual(TemperatureMeter.level(forCelsius: 140), CPUMeter.steps)
        XCTAssertNil(TemperatureMeter.level(forCelsius: nil))
        XCTAssertNil(TemperatureMeter.level(forCelsius: .nan))
    }
}

final class LoadHistoryTests: XCTestCase {
    func testKeepsOnlyTheNewestReadings() {
        // Arrange
        var history = LoadHistory()

        // Act
        for index in 0..<(LoadHistory.capacity + 5) {
            history.append(SystemReadings(cpuPercent: Double(index), temperatureCelsius: Double(index) + 40))
        }

        // Assert
        XCTAssertEqual(history.readings.count, LoadHistory.capacity)
        XCTAssertEqual(history.readings.first?.cpuPercent, 5)
        XCTAssertEqual(history.readings.last?.cpuPercent, Double(LoadHistory.capacity + 4))
        XCTAssertEqual(history.readings.last?.temperatureCelsius, Double(LoadHistory.capacity + 44))
    }

    func testKeepsMissingReadingsInPlace() {
        // Arrange
        var history = LoadHistory()

        // Act
        history.append(SystemReadings(cpuPercent: nil, temperatureCelsius: 50))
        history.append(SystemReadings(cpuPercent: 20, temperatureCelsius: nil))

        // Assert
        XCTAssertEqual(history.readings.map(\.cpuPercent), [nil, 20])
        XCTAssertEqual(history.readings.map(\.temperatureCelsius), [50, nil])
    }
}

final class HistoryGraphTests: XCTestCase {
    func testPadsAtTheFrontSoTheNewestIsAtTheRight() {
        // Arrange
        var history = LoadHistory()
        history.append(SystemReadings(cpuPercent: 50, temperatureCelsius: 65))

        // Act
        let cpu = HistoryGraph.levels(history, parameter: .cpu, rows: 2)
        let temperature = HistoryGraph.levels(history, parameter: .temperature, rows: 2)

        // Assert
        XCTAssertEqual(cpu.count, LoadHistory.capacity)
        XCTAssertEqual(cpu.dropLast().compactMap { $0 }, [])
        XCTAssertEqual(cpu.last, 4)
        XCTAssertEqual(temperature.count, LoadHistory.capacity)
        XCTAssertEqual(temperature.last, 4)
    }

    func testAnEmptyHistoryIsAllGaps() {
        XCTAssertEqual(HistoryGraph.levels(LoadHistory(), parameter: .cpu, rows: 2),
                       Array(repeating: nil, count: LoadHistory.capacity))
    }

    func testAMissingReadingIsAGapNotTheFloor() {
        // Arrange
        var history = LoadHistory()
        history.append(SystemReadings(cpuPercent: nil, temperatureCelsius: .nan))
        history.append(SystemReadings(cpuPercent: 0, temperatureCelsius: 20))

        // Act
        let cpu = HistoryGraph.levels(history, parameter: .cpu, rows: 2).suffix(2)
        let temperature = HistoryGraph.levels(history, parameter: .temperature, rows: 2).suffix(2)

        // Assert
        XCTAssertEqual(Array(cpu), [nil, 0])
        XCTAssertEqual(Array(temperature), [nil, 0])
    }

    func testEveryRowCountFitsTheMenuBarHeight() {
        for rows in HistoryGraph.rowChoices {
            let gaps = Double(rows - 1) * HistoryGraph.rowGap(rows: rows)
            XCTAssertLessThanOrEqual(Double(rows * HistoryGraph.rowHeight(rows: rows)) + gaps, 18, "\(rows) rows")
            XCTAssertGreaterThan(HistoryGraph.rowGap(rows: rows), 0, "\(rows) rows")
        }
    }

    func testTwoRowsStepInPointsAndMoreRowsInHalfPoints() {
        XCTAssertEqual(HistoryGraph.steps(rows: 2), 7)
        XCTAssertEqual(HistoryGraph.steps(rows: 3), 10)
        XCTAssertEqual(HistoryGraph.steps(rows: 4), 8)
    }

    func testTheScaleFollowsTheRowCount() {
        // Arrange
        var history = LoadHistory()
        history.append(SystemReadings(
            cpuPercent: 100,
            memory: MemoryUsage(usedBytes: 50, totalBytes: 100),
            swap: SwapUsage(usedBytes: 1, allocatedBytes: 10, physicalMemoryBytes: 1_000)
        ))

        // Act / Assert
        for rows in HistoryGraph.rowChoices {
            let steps = HistoryGraph.steps(rows: rows)
            XCTAssertEqual(HistoryGraph.levels(history, parameter: .cpu, rows: rows).last, steps, "\(rows) rows")
            XCTAssertEqual(HistoryGraph.levels(history, parameter: .memory, rows: rows).last,
                           Int((Double(steps) / 2).rounded()), "\(rows) rows")
            // Anything above zero stands one step, on every scale.
            XCTAssertEqual(HistoryGraph.levels(history, parameter: .swap, rows: rows).last, 1, "\(rows) rows")
        }
    }

    func testRowCountsOutsideTheChoicesAreHeld() {
        XCTAssertEqual(HistoryGraph.clampedRows(0), 2)
        XCTAssertEqual(HistoryGraph.clampedRows(3), 3)
        XCTAssertEqual(HistoryGraph.clampedRows(99), 4)
    }

    func testRowNamesRunFromTopToBottom() {
        XCTAssertEqual(HistoryGraph.rowNames(count: 2), ["top row", "bottom row"])
        XCTAssertEqual(HistoryGraph.rowNames(count: 3), ["top row", "middle row", "bottom row"])
        XCTAssertEqual(HistoryGraph.rowNames(count: 4), ["top row", "row 2", "row 3", "bottom row"])
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

    func testTheSteamFollowsItsOwnLevelWhenThereIsOne() {
        XCTAssertEqual(CoffeeCup.forLevel(CPUMeter.steps, steamLevel: 0).steamLines, 0)
        XCTAssertEqual(CoffeeCup.forLevel(0, steamLevel: 8).steamLines, 3)
        XCTAssertTrue(CoffeeCup.forLevel(CPUMeter.steps, steamLevel: 0).overflowing)
        XCTAssertEqual(CoffeeCup.forLevel(5, steamLevel: nil).steamLines, 2)
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

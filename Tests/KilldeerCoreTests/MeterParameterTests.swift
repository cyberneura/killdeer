import XCTest
@testable import KilldeerCore

final class MeterParameterOrderTests: XCTestCase {
    func testNothingStoredGivesTheDefaultOrder() {
        XCTAssertEqual(MeterParameterOrder.parse(nil), [.cpu, .temperature, .memory, .swap])
        XCTAssertEqual(MeterParameterOrder.parse([]), MeterParameterOrder.default)
    }

    func testAStoredOrderIsKept() {
        XCTAssertEqual(MeterParameterOrder.parse(["swap", "memory", "cpu", "temperature"]),
                       [.swap, .memory, .cpu, .temperature])
    }

    func testUnknownNamesAndRepeatsAreDroppedAndTheMissingFollow() {
        // Arrange: a value another build might have written.
        let stored = ["memory", "gpu", "memory", "cpu"]

        // Act
        let order = MeterParameterOrder.parse(stored)

        // Assert: what was stored leads, the rest follow in the default order.
        XCTAssertEqual(order, [.memory, .cpu, .temperature, .swap])
    }

    func testEveryParsedOrderHoldsEachParameterOnce() {
        for stored in [nil, [], ["swap"], ["x", "y"], ["cpu", "cpu", "cpu"]] as [[String]?] {
            let order = MeterParameterOrder.parse(stored)
            XCTAssertEqual(order.count, MeterParameter.allCases.count)
            XCTAssertEqual(Set(order), Set(MeterParameter.allCases))
        }
    }

    func testMovingShiftsOnePlace() {
        let order = MeterParameterOrder.default
        XCTAssertEqual(MeterParameterOrder.moving(.memory, by: -1, in: order), [.cpu, .memory, .temperature, .swap])
        XCTAssertEqual(MeterParameterOrder.moving(.cpu, by: 1, in: order), [.temperature, .cpu, .memory, .swap])
    }

    func testMovingStopsAtTheEnds() {
        let order = MeterParameterOrder.default
        XCTAssertEqual(MeterParameterOrder.moving(.cpu, by: -1, in: order), order)
        XCTAssertEqual(MeterParameterOrder.moving(.swap, by: 1, in: order), order)
        XCTAssertEqual(MeterParameterOrder.moving(.cpu, by: 99, in: order), [.temperature, .memory, .swap, .cpu])
    }

    func testAMacWithNoSensorPassesOverTheTemperature() {
        let order: [MeterParameter] = [.temperature, .cpu, .memory, .swap]
        XCTAssertEqual(MeterParameterOrder.drawable(order, temperatureAvailable: false), [.cpu, .memory, .swap])
        XCTAssertEqual(MeterParameterOrder.drawable(order, temperatureAvailable: true), order)
    }
}

final class MeterSlotTests: XCTestCase {
    private let order: [MeterParameter] = [.memory, .swap, .cpu, .temperature]

    func testOneSlotStylesShowTheFirstParameter() {
        for style in [MeterStyle.birdWithGauge, .flappingBird, .moonPhase, .weather] {
            XCTAssertEqual(style.slots(order: order).map(\.parameter), [.memory], style.rawValue)
        }
    }

    func testTwoSlotStylesShowTheFirstTwo() {
        XCTAssertEqual(MeterStyle.ringGauge.slots(order: order),
                       [MeterSlot(.memory, part: "outer ring"), MeterSlot(.swap, part: "inner ring")])
        XCTAssertEqual(MeterStyle.coffeeCup.slots(order: order),
                       [MeterSlot(.memory, part: "coffee"), MeterSlot(.swap, part: "steam")])
    }

    func testCoreBarsAreTheCPUWhateverTheOrder() {
        XCTAssertEqual(MeterStyle.coreBars.slots(order: order).map(\.parameter), [.cpu])
    }

    func testTheHeatmapsSideMeterIsTheFirstParameterThatIsNotTheCPU() {
        XCTAssertEqual(MeterStyle.coreHeatmap.slots(order: [.cpu, .swap, .memory, .temperature]).map(\.parameter),
                       [.cpu, .swap])
        XCTAssertEqual(MeterStyle.coreHeatmap.slots(order: order).map(\.parameter), [.cpu, .memory])
    }

    func testTheHistoryGraphShowsAsManyAsItHasRows() {
        XCTAssertEqual(MeterStyle.historyGraph.slots(order: order, historyRows: 2).map(\.parameter), [.memory, .swap])
        XCTAssertEqual(MeterStyle.historyGraph.slots(order: order, historyRows: 3).map(\.parameter),
                       [.memory, .swap, .cpu])
        XCTAssertEqual(MeterStyle.historyGraph.slots(order: order, historyRows: 4).map(\.parameter), order)
    }

    func testTheHistoryGraphNamesItsRowsForTheRowsItDraws() {
        // Arrange: no sensor, so three parameters for a graph set to four rows.
        let drawable = MeterParameterOrder.drawable(order, temperatureAvailable: false)

        // Act
        let slots = MeterStyle.historyGraph.slots(order: drawable, historyRows: 4)

        // Assert
        XCTAssertEqual(slots, [
            MeterSlot(.memory, part: "top row"),
            MeterSlot(.swap, part: "middle row"),
            MeterSlot(.cpu, part: "bottom row"),
        ])
    }

    func testNoStyleShowsAParameterTwice() {
        for style in MeterStyle.allCases {
            for rows in HistoryGraph.rowChoices {
                let parameters = style.slots(order: order, historyRows: rows).map(\.parameter)
                XCTAssertEqual(parameters.count, Set(parameters).count, "\(style.rawValue), \(rows) rows")
                XCTAssertFalse(parameters.isEmpty, style.rawValue)
            }
        }
    }
}

final class SystemReadingsTests: XCTestCase {
    private let readings = SystemReadings(
        cpuPercent: 50,
        temperatureCelsius: 65,
        memory: MemoryUsage(usedBytes: 80, totalBytes: 100),
        swap: SwapUsage(usedBytes: 30, allocatedBytes: 40, physicalMemoryBytes: 100)
    )

    func testEachParameterIsReadOnItsOwnScale() {
        XCTAssertEqual(readings.level(of: .cpu), 5)
        XCTAssertEqual(readings.level(of: .temperature), 5)
        XCTAssertEqual(readings.level(of: .memory), 8)
        // Against the RAM, not against what is allocated: 30 of 40 would be 8.
        XCTAssertEqual(readings.level(of: .swap), 3)
    }

    func testNoReadingIsNilRatherThanZero() {
        let empty = SystemReadings()
        for parameter in MeterParameter.allCases {
            XCTAssertNil(empty.level(of: parameter), parameter.rawValue)
        }
    }

    func testAnythingAboveZeroShowsOneStep() {
        // Arrange
        let slight = SystemReadings(
            cpuPercent: 0.4,
            memory: MemoryUsage(usedBytes: 1, totalBytes: 1_000),
            swap: SwapUsage(usedBytes: 1, allocatedBytes: 1_000, physicalMemoryBytes: 1_000_000)
        )
        let none = SystemReadings(
            cpuPercent: 0,
            swap: SwapUsage(usedBytes: 0, allocatedBytes: 1_000, physicalMemoryBytes: 1_000_000)
        )

        // Act / Assert
        XCTAssertEqual(slight.level(of: .cpu), 1)
        XCTAssertEqual(slight.level(of: .memory), 1)
        XCTAssertEqual(slight.level(of: .swap), 1)
        XCTAssertEqual(none.level(of: .cpu), 0)
        XCTAssertEqual(none.level(of: .swap), 0)
    }
}

final class MeterLevelsTests: XCTestCase {
    private let readings = SystemReadings(
        cpuPercent: 20,
        temperatureCelsius: 100,
        memory: MemoryUsage(usedBytes: 80, totalBytes: 100),
        swap: SwapUsage(usedBytes: 30, allocatedBytes: 40, physicalMemoryBytes: 100)
    )

    private func levels(_ style: MeterStyle, order: [MeterParameter], rows: Int = 4,
                        readings: SystemReadings? = nil, history: LoadHistory = LoadHistory()) -> MeterLevels {
        MeterLevels(style: style, slots: style.slots(order: order, historyRows: rows),
                    readings: readings ?? self.readings, history: history)
    }

    func testTheOrderDecidesWhichLevelIsWhere() {
        XCTAssertEqual(levels(.ringGauge, order: [.cpu, .temperature, .memory, .swap]),
                       MeterLevels(primary: 2, secondary: 10))
        XCTAssertEqual(levels(.ringGauge, order: [.memory, .swap, .cpu, .temperature]),
                       MeterLevels(primary: 8, secondary: 3))
    }

    func testAOneSlotStyleHasNoSecondLevel() {
        XCTAssertEqual(levels(.weather, order: [.swap, .cpu, .memory, .temperature]), MeterLevels(primary: 3))
    }

    func testTheHeatmapCarriesOnlyItsSideMeter() {
        // The tiles come from the cores, so the first level stays out of the
        // picture's key.
        XCTAssertEqual(levels(.coreHeatmap, order: [.cpu, .memory, .swap, .temperature]),
                       MeterLevels(primary: 0, secondary: 8))
        XCTAssertEqual(levels(.coreBars, order: [.memory, .cpu, .swap, .temperature]), MeterLevels())
    }

    func testAMissingReadingDrawsTheFirstSlotEmptyAndTheSecondAbsent() {
        let result = levels(.coffeeCup, order: [.cpu, .temperature, .memory, .swap], readings: SystemReadings())
        XCTAssertEqual(result, MeterLevels(primary: 0, secondary: nil))
    }

    func testTheHistoryGraphHasARowPerSlotInOrder() {
        // Arrange
        var history = LoadHistory()
        history.append(readings)

        // Act
        let result = levels(.historyGraph, order: [.swap, .cpu, .memory, .temperature], rows: 3, history: history)

        // Assert: three rows on the ten-step scale, newest reading last.
        XCTAssertEqual(result.primary, 0)
        XCTAssertNil(result.secondary)
        XCTAssertEqual(result.history.map(\.count), Array(repeating: LoadHistory.capacity, count: 3))
        XCTAssertEqual(result.history.map(\.last), [3, 2, 8])
    }
}

final class ParameterLineTests: XCTestCase {
    private let gigabyte: UInt64 = 1_073_741_824
    private var readings: SystemReadings {
        SystemReadings(
            cpuPercent: 12.34,
            temperatureCelsius: 45.67,
            memory: MemoryUsage(usedBytes: 20 * gigabyte, totalBytes: 24 * gigabyte),
            swap: SwapUsage(usedBytes: 7_200 * 1_048_576, allocatedBytes: 8 * gigabyte, physicalMemoryBytes: 24 * gigabyte)
        )
    }

    func testOneLinePerParameterInTheGivenOrder() {
        // Arrange
        let order: [MeterParameter] = [.memory, .cpu, .swap, .temperature]

        // Act
        let lines = ParameterLine.lines(order: order, slots: [], readings: readings)

        // Assert
        XCTAssertEqual(lines, [
            "Memory 83.3% (20.0 of 24 GB)",
            "CPU 12.3%",
            "Swap 7.0 GB (29% of RAM)",
            "Temperature 45.7 °C",
        ])
    }

    func testAParameterInThePictureNamesItsPart() {
        // Arrange
        let order: [MeterParameter] = [.cpu, .temperature, .memory, .swap]

        // Act
        let lines = ParameterLine.lines(order: order, slots: MeterStyle.ringGauge.slots(order: order), readings: readings)

        // Assert
        XCTAssertEqual(lines[0], "CPU 12.3% — outer ring")
        XCTAssertEqual(lines[1], "Temperature 45.7 °C — inner ring")
        XCTAssertEqual(lines[2], "Memory 83.3% (20.0 of 24 GB)")
    }

    func testAMissingReadingKeepsItsLine() {
        let lines = ParameterLine.lines(order: MeterParameterOrder.default, slots: [], readings: SystemReadings())
        XCTAssertEqual(lines, ["CPU —", "Temperature —", "Memory —", "Swap —"])
    }

    func testSwapUnderAGigabyteIsInMegabytes() {
        let none = SystemReadings(swap: SwapUsage(usedBytes: 0, allocatedBytes: 0, physicalMemoryBytes: 24 * gigabyte))
        XCTAssertEqual(ParameterLine.text(.swap, readings: none), "Swap 0 MB (0% of RAM)")
    }

    func testSpokenFiguresLeaveOutWhatWasNotRead() {
        let spoken = ParameterLine.spoken(
            order: [.memory, .cpu, .swap, .temperature],
            readings: SystemReadings(cpuPercent: 12.3, memory: MemoryUsage(usedBytes: 1, totalBytes: 2))
        )
        XCTAssertEqual(spoken, ["memory 50%", "CPU 12%"])
    }
}

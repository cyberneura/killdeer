import XCTest
@testable import KilldeerCore

final class MemoryUsageTests: XCTestCase {
    func testUsedIsAppWiredAndCompressedWithoutTheFileCache() {
        // Arrange: the figures of a 24 GB Mac, in 16 KiB pages. Active,
        // inactive and speculative hold the app memory together with the file
        // cache (external) and the purgeable pages.
        let pages = VMPageCounts(
            active: 400_000, inactive: 380_000, speculative: 20_000, wired: 180_000,
            compressed: 680_000, purgeable: 30_000, external: 320_000
        )

        // Act
        let usage = MemoryUsage(pages: pages, pageSize: 16_384, totalBytes: 24 * 1_073_741_824)

        // Assert
        XCTAssertEqual(pages.usedPages, 1_310_000)
        XCTAssertEqual(usage.usedBytes, 1_310_000 * 16_384)
        XCTAssertEqual(usage.percent, 83.29, accuracy: 0.01)
    }

    func testCountersThatDoNotAddUpGiveZeroRatherThanWrapping() {
        // The counters are read one after another while the system runs, so
        // nothing promises the reclaimable ones stay under the rest.
        let pages = VMPageCounts(active: 10, purgeable: 8, external: 8)
        XCTAssertEqual(pages.usedPages, 0)
    }

    func testThePercentageIsHeldToAHundred() {
        XCTAssertEqual(MemoryUsage(usedBytes: 150, totalBytes: 100).percent, 100)
        XCTAssertEqual(MemoryUsage(usedBytes: 25, totalBytes: 100).percent, 25)
    }

    func testNoMemoryReportedIsZeroNotADivisionByZero() {
        XCTAssertEqual(MemoryUsage(usedBytes: 10, totalBytes: 0).percent, 0)
    }

    func testTheKernelAnswersWithSomethingPlausible() throws {
        // Act
        let usage = try XCTUnwrap(MemoryStats.sampleMemory())

        // Assert
        XCTAssertEqual(usage.totalBytes, ProcessInfo.processInfo.physicalMemory)
        XCTAssertGreaterThan(usage.usedBytes, 0)
        XCTAssertLessThanOrEqual(usage.usedBytes, usage.totalBytes)
    }
}

final class SwapUsageTests: XCTestCase {
    func testThePercentageIsOfTheRAMNotOfTheAllocation() {
        // Arrange: 7.2 GB used of 8 GB allocated, on a 24 GB Mac.
        let megabyte: UInt64 = 1_048_576
        let swap = SwapUsage(usedBytes: 7_200 * megabyte, allocatedBytes: 8_192 * megabyte,
                             physicalMemoryBytes: 24_576 * megabyte)

        // Act / Assert: 88% of the allocation, 29% of the RAM.
        XCTAssertEqual(swap.percentOfMemory, 29.3, accuracy: 0.05)
    }

    func testGrowingTheAllocationDoesNotMoveTheFigure() {
        let before = SwapUsage(usedBytes: 7, allocatedBytes: 8, physicalMemoryBytes: 24)
        let after = SwapUsage(usedBytes: 7, allocatedBytes: 16, physicalMemoryBytes: 24)
        XCTAssertEqual(before.percentOfMemory, after.percentOfMemory)
    }

    func testMoreSwapThanRAMIsHeldToAHundred() {
        XCTAssertEqual(SwapUsage(usedBytes: 50, allocatedBytes: 60, physicalMemoryBytes: 24).percentOfMemory, 100)
        XCTAssertEqual(SwapUsage(usedBytes: 5, allocatedBytes: 6, physicalMemoryBytes: 0).percentOfMemory, 0)
    }

    func testTheKernelAnswers() throws {
        // Act
        let swap = try XCTUnwrap(MemoryStats.sampleSwap())

        // Assert
        XCTAssertLessThanOrEqual(swap.usedBytes, swap.allocatedBytes)
        XCTAssertEqual(swap.physicalMemoryBytes, ProcessInfo.processInfo.physicalMemory)
    }
}

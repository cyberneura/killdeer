import XCTest
@testable import KilldeerCore

/// Writes the LevelDB formats the reader has to understand, the way LevelDB
/// itself lays them out, so the tests exercise the reader against real
/// structure rather than against its own assumptions.
private enum LevelDBWriter {
    static func varint(_ value: Int) -> [UInt8] {
        var value = UInt64(value)
        var bytes: [UInt8] = []
        while value >= 0x80 {
            bytes.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        bytes.append(UInt8(value))
        return bytes
    }

    static func le32(_ value: UInt32) -> [UInt8] { (0 ..< 4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
    static func le64(_ value: UInt64) -> [UInt8] { (0 ..< 8).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }

    enum Operation {
        case put(String, [UInt8])
        case delete(String)
    }

    static func batch(sequence: UInt64, _ operations: [Operation]) -> [UInt8] {
        var bytes = le64(sequence) + le32(UInt32(operations.count))
        for operation in operations {
            switch operation {
            case let .put(key, value):
                bytes += [1] + varint(key.utf8.count) + Array(key.utf8) + varint(value.count) + value
            case let .delete(key):
                bytes += [0] + varint(key.utf8.count) + Array(key.utf8)
            }
        }
        return bytes
    }

    static func log(_ records: [[UInt8]]) -> [UInt8] {
        var file: [UInt8] = []
        var blockOffset = 0
        for record in records {
            var left = record[...]
            var begin = true
            repeat {
                if 32768 - blockOffset < 7 {
                    file += [UInt8](repeating: 0, count: 32768 - blockOffset)
                    blockOffset = 0
                }
                let length = min(32768 - blockOffset - 7, left.count)
                let end = length == left.count
                let type: UInt8 = begin && end ? 1 : begin ? 2 : end ? 4 : 3
                let data = left.prefix(length)
                file += le32(CRC32C.masked(CRC32C.checksum(type: type, ArraySlice(data)))) + [UInt8(length & 0xff), UInt8(length >> 8), type] + data
                blockOffset += 7 + length
                left = left.dropFirst(length)
                begin = false
            } while !left.isEmpty
        }
        return file
    }

    static func internalKey(_ key: String, sequence: UInt64, deleted: Bool = false) -> [UInt8] {
        Array(key.utf8) + le64(sequence << 8 | (deleted ? 0 : 1))
    }

    /// One block, prefix-compressed against the previous key as LevelDB does.
    static func block(_ entries: [([UInt8], [UInt8])]) -> [UInt8] {
        var bytes: [UInt8] = []
        var previous: [UInt8] = []
        for (key, value) in entries {
            let shared = zip(previous, key).prefix { $0 == $1 }.count
            bytes += varint(shared) + varint(key.count - shared) + varint(value.count) + key[shared...] + value
            previous = key
        }
        return bytes + le32(0) + le32(1)
    }

    /// A raw Snappy stream holding the input as one literal.
    static func snappyLiteral(_ input: [UInt8]) -> [UInt8] {
        let length = input.count - 1
        let tag: [UInt8]
        switch length {
        case ..<60: tag = [UInt8(length << 2)]
        case ..<256: tag = [60 << 2, UInt8(length)]
        case ..<65536: tag = [61 << 2, UInt8(length & 0xff), UInt8(length >> 8)]
        default: tag = [62 << 2] + le32(UInt32(length)).prefix(3)
        }
        return varint(input.count) + tag + input
    }

    /// A table with one data block per group of entries.
    /// `indexRepeats` lists each index entry that many times over, as a
    /// damaged table might.
    static func table(_ groups: [[([UInt8], [UInt8])]], compressed: Bool, indexRepeats: Int = 1) -> [UInt8] {
        var file: [UInt8] = []
        var index: [([UInt8], [UInt8])] = []
        func append(_ contents: [UInt8], compressionType: UInt8) -> [UInt8] {
            let handle = varint(file.count) + varint(contents.count)
            file += contents + [compressionType] + le32(CRC32C.masked(CRC32C.checksum(contents + [compressionType])))
            return handle
        }
        for group in groups {
            let raw = block(group)
            let handle = compressed ? append(snappyLiteral(raw), compressionType: 1) : append(raw, compressionType: 0)
            index += Array(repeating: (group.last!.0, handle), count: indexRepeats)
        }
        let metaindex = append(block([]), compressionType: 0)
        let indexHandle = append(block(index), compressionType: 0)
        var footer = metaindex + indexHandle
        footer += [UInt8](repeating: 0, count: 40 - footer.count)
        return file + footer + le64(0xdb47_7524_8b80_fb57)
    }
}

private func json(_ string: String) -> [UInt8] { Array("\"\(string)\"".utf8) }

/// A fixed generator so a failure in the corrupt-input tests reproduces.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

final class LevelDBTests: XCTestCase {
    private let key = Array("bridgeDeviceId".utf8)

    func testCRC32CMatchesTheStandardCheckValue() {
        // Act / Assert
        XCTAssertEqual(CRC32C.checksum(Array("123456789".utf8)), 0xe306_9283)
    }

    func testFindsAValueWrittenToTheLog() {
        // Arrange
        let log = LevelDBWriter.log([
            LevelDBWriter.batch(sequence: 1, [.put("other", json("x")), .put("bridgeDeviceId", json("abc"))])
        ])

        // Act
        let result = LevelDB.lookup(key: key, logs: [log], tables: [])

        // Assert
        XCTAssertEqual(result, .value(json("abc")))
    }

    func testLaterDeletionInTheLogHidesTheValue() {
        // Arrange
        let log = LevelDBWriter.log([
            LevelDBWriter.batch(sequence: 1, [.put("bridgeDeviceId", json("abc"))]),
            LevelDBWriter.batch(sequence: 2, [.delete("bridgeDeviceId")])
        ])

        // Act / Assert
        XCTAssertEqual(LevelDB.lookup(key: key, logs: [log], tables: []), .deleted)
    }

    func testAKeyThatOnlySharesAPrefixDoesNotMatch() {
        // Arrange
        let log = LevelDBWriter.log([LevelDBWriter.batch(sequence: 1, [.put("bridgeDeviceIdOld", json("abc"))])])

        // Act / Assert
        XCTAssertEqual(LevelDB.lookup(key: key, logs: [log], tables: []), .absent)
    }

    /// A value over a block's worth of bytes is split into first, middle and
    /// last fragments; reading only the first one would lose the value.
    func testReassemblesARecordSplitAcrossLogBlocks() {
        // Arrange
        let big = [UInt8](repeating: 0x61, count: 70000)
        let log = LevelDBWriter.log([
            LevelDBWriter.batch(sequence: 1, [.put("padding", big)]),
            LevelDBWriter.batch(sequence: 2, [.put("bridgeDeviceId", json("after-the-big-one"))])
        ])

        // Act
        let records = LevelDB.logRecords(in: log)

        // Assert
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(LevelDB.lookup(key: key, logs: [log], tables: []), .value(json("after-the-big-one")))
    }

    /// The browser is appending to its newest log while Killdeer reads it.
    func testIncompleteLastRecordIsIgnoredAndEarlierOnesKept() {
        // Arrange
        let log = LevelDBWriter.log([
            LevelDBWriter.batch(sequence: 1, [.put("bridgeDeviceId", json("old"))]),
            LevelDBWriter.batch(sequence: 2, [.put("bridgeDeviceId", json("new"))])
        ])

        // Act
        let truncated = Array(log.dropLast(3))

        // Assert
        XCTAssertEqual(LevelDB.lookup(key: key, logs: [truncated], tables: []), .value(json("old")))
    }

    func testRecordWithABadChecksumIsSkipped() {
        // Arrange
        var log = LevelDBWriter.log([LevelDBWriter.batch(sequence: 1, [.put("bridgeDeviceId", json("abc"))])])
        log[log.count - 2] ^= 0xff

        // Act / Assert
        XCTAssertEqual(LevelDB.lookup(key: key, logs: [log], tables: []), .absent)
    }

    func testFindsAValueInASnappyCompressedTable() {
        // Arrange
        let table = LevelDBWriter.table([[
            (LevelDBWriter.internalKey("aaa", sequence: 3), json("a")),
            (LevelDBWriter.internalKey("bridgeDeviceId", sequence: 9), json("from-table")),
            (LevelDBWriter.internalKey("zzz", sequence: 4), json("z"))
        ]], compressed: true)

        // Act / Assert
        XCTAssertEqual(LevelDB.lookup(key: key, logs: [], tables: [table]), .value(json("from-table")))
    }

    /// The index lets the reader skip blocks; it must not skip the one that
    /// holds the key, whether that block is first, in the middle or last.
    func testFindsTheKeyInWhicheverDataBlockHoldsIt() {
        // Arrange
        let before = [(LevelDBWriter.internalKey("alpha", sequence: 1), json("a"))]
        let target = [(LevelDBWriter.internalKey("bridgeDeviceId", sequence: 2), json("found"))]
        let after = [(LevelDBWriter.internalKey("zulu", sequence: 3), json("z"))]

        // Act
        let layouts = [[target, after], [before, target, after], [before, target]]

        // Assert
        for groups in layouts {
            let table = LevelDBWriter.table(groups, compressed: false)
            XCTAssertEqual(LevelDB.lookup(key: key, logs: [], tables: [table]), .value(json("found")))
        }
    }

    func testHighestSequenceWinsBetweenLogAndTable() {
        // Arrange
        let table = LevelDBWriter.table([[(LevelDBWriter.internalKey("bridgeDeviceId", sequence: 10), json("table"))]], compressed: true)
        let older = LevelDBWriter.log([LevelDBWriter.batch(sequence: 5, [.put("bridgeDeviceId", json("old-log"))])])
        let newer = LevelDBWriter.log([LevelDBWriter.batch(sequence: 20, [.put("bridgeDeviceId", json("new-log"))])])

        // Act / Assert
        XCTAssertEqual(LevelDB.lookup(key: key, logs: [older], tables: [table]), .value(json("table")))
        XCTAssertEqual(LevelDB.lookup(key: key, logs: [newer], tables: [table]), .value(json("new-log")))
    }

    func testNewerDeletionInATableHidesAnOlderValue() {
        // Arrange
        let table = LevelDBWriter.table([[
            (LevelDBWriter.internalKey("bridgeDeviceId", sequence: 8, deleted: true), []),
            (LevelDBWriter.internalKey("bridgeDeviceId", sequence: 7), json("gone"))
        ]], compressed: false)

        // Act / Assert
        XCTAssertEqual(LevelDB.lookup(key: key, logs: [], tables: [table]), .deleted)
    }

    /// A flipped byte inside a stored value still parses; only the block
    /// checksum tells it from the real ID.
    func testTableBlockWithABadChecksumIsSkipped() {
        // Arrange
        var table = LevelDBWriter.table([[(LevelDBWriter.internalKey("bridgeDeviceId", sequence: 2), json("found"))]], compressed: false)
        let valueOffset = table.firstIndex(of: UInt8(ascii: "f"))!

        // Act
        table[valueOffset] = UInt8(ascii: "g")

        // Assert
        XCTAssertEqual(LevelDB.lookup(key: key, logs: [], tables: [table]), .absent)
    }

    /// LevelDB drops the rest of a damaged block and resumes at the next.
    func testDamagedLogBlockDoesNotHideLaterBlocks() {
        // Arrange
        let filler = [UInt8](repeating: 0x61, count: 40000)
        var log = LevelDBWriter.log([
            LevelDBWriter.batch(sequence: 1, [.put("filler", filler)]),
            LevelDBWriter.batch(sequence: 2, [.put("bridgeDeviceId", json("in-a-later-block"))])
        ])

        // Act: an impossible length in the first record's header.
        log[4] = 0xff
        log[5] = 0xff

        // Assert
        XCTAssertEqual(LevelDB.lookup(key: key, logs: [log], tables: []), .value(json("in-a-later-block")))
    }

    func testLastWriteInABatchWins() {
        // Arrange
        let batch = LevelDBWriter.batch(sequence: 10, [
            .put("bridgeDeviceId", json("first")), .put("other", json("x")), .put("bridgeDeviceId", json("last"))
        ])

        // Act / Assert
        XCTAssertEqual(LevelDB.batchEntry(for: key, in: batch), LevelDB.Entry(sequence: 12, value: json("last")))
    }

    func testVarintOverflowingSixtyFourBitsIsRejected() {
        // Arrange: nine continuation bytes, then a tenth carrying more than one bit.
        var overflowing = ByteReader([UInt8](repeating: 0x80, count: 9) + [0x02])
        var largest = ByteReader([UInt8](repeating: 0xff, count: 8) + [0x7f])

        // Act / Assert
        XCTAssertNil(overflowing.varint())
        XCTAssertEqual(largest.varint(), Int.max)
    }

    func testBatchWithBytesItsCountDoesNotCoverIsDropped() {
        // Arrange
        let batch = LevelDBWriter.batch(sequence: 1, [.put("bridgeDeviceId", json("abc"))]) + [1, 0]

        // Act / Assert
        XCTAssertNil(LevelDB.batchEntry(for: key, in: batch))
    }

    func testBatchWithASequenceBeyond56BitsIsDropped() {
        // Arrange
        let batch = LevelDBWriter.batch(sequence: 1 << 56, [.put("bridgeDeviceId", json("abc"))])

        // Act / Assert
        XCTAssertNil(LevelDB.batchEntry(for: key, in: batch))
        XCTAssertNotNil(LevelDB.batchEntry(for: key, in: LevelDBWriter.batch(sequence: (1 << 56) - 1, [.put("bridgeDeviceId", json("abc"))])))
    }

    /// Thousands of entries that each share a long prefix cost one key's
    /// worth of memory, not one copy per entry.
    func testLongSharedPrefixesAreNotCopiedPerEntry() {
        // Arrange
        let longKey = [UInt8](repeating: 0x7a, count: 60000)
        var block = LevelDBWriter.varint(0) + LevelDBWriter.varint(longKey.count) + LevelDBWriter.varint(0) + longKey
        for _ in 0 ..< 20000 { block += LevelDBWriter.varint(longKey.count) + LevelDBWriter.varint(0) + LevelDBWriter.varint(0) }
        block += LevelDBWriter.le32(0) + LevelDBWriter.le32(1)

        // Act
        var visited = 0
        LevelDB.forEachBlockEntry(block) { _, _ in
            visited += 1
            return true
        }

        // Assert
        XCTAssertEqual(visited, 20001)
    }

    func testAVeryLongKeyBeforeTheTargetDoesNotHideIt() {
        // Arrange
        let longKey = String(repeating: "a", count: 200_000)
        let table = LevelDBWriter.table([
            [(LevelDBWriter.internalKey(longKey, sequence: 1), json("long")),
             (LevelDBWriter.internalKey("bridgeDeviceId", sequence: 2), json("same-block"))],
            [(LevelDBWriter.internalKey("c" + longKey, sequence: 3), json("long"))]
        ], compressed: true)

        // Act / Assert
        XCTAssertEqual(LevelDB.lookup(key: key, logs: [], tables: [table]), .value(json("same-block")))
    }

    /// An index that lists the same data block over and over reads it once.
    func testRepeatedIndexHandlesAreReadOnce() {
        // Arrange
        let table = LevelDBWriter.table(
            [[(LevelDBWriter.internalKey("bridgeDeviceId", sequence: 2), json("found"))]],
            compressed: false, indexRepeats: 3
        )

        // Act
        let entry = LevelDB.tableEntry(for: key, in: table)

        // Assert
        XCTAssertEqual(entry, LevelDB.Entry(sequence: 2, value: json("found")))
    }

    /// LevelDB's reader ends a record being assembled at a zero header, so a
    /// stray last fragment after one cannot be joined to the first.
    func testZeroHeaderEndsARecordBeingAssembled() {
        // Arrange: a first fragment, zero padding to the block end, then a
        // last fragment that together with the first would be a valid batch.
        let batch = LevelDBWriter.batch(sequence: 1, [.put("bridgeDeviceId", json("joined"))])
        let head = Array(batch.prefix(10))
        let tail = Array(batch.dropFirst(10))
        func record(_ type: UInt8, _ data: [UInt8]) -> [UInt8] {
            LevelDBWriter.le32(CRC32C.masked(CRC32C.checksum(type: type, data[...]))) + [UInt8(data.count), 0, type] + data
        }
        var log = record(2, head)
        log += [UInt8](repeating: 0, count: 32768 - log.count)
        log += record(4, tail)

        // Act / Assert
        XCTAssertEqual(LevelDB.lookup(key: key, logs: [log], tables: []), .absent)
    }

    func testSnappyCopiesRepeatTheBytesTheyPointBackTo() {
        // Arrange: the literal "abc", then a 6-byte copy from 3 bytes back.
        let compressed: [UInt8] = [9, 2 << 2] + Array("abc".utf8) + [(2 << 2) | 1, 3]

        // Act / Assert
        XCTAssertEqual(Snappy.decompress(compressed[...], limit: 100), Array("abcabcabc".utf8))
    }

    func testSnappyRejectsCopiesThatPointOutsideTheOutput() {
        // Arrange
        let zeroOffset: [UInt8] = [7, 2 << 2] + Array("abc".utf8) + [1, 0]
        let beforeStart: [UInt8] = [7, 2 << 2] + Array("abc".utf8) + [1, 9]
        let overlong: [UInt8] = [4, 2 << 2] + Array("abc".utf8) + [(2 << 2) | 1, 3]

        // Act / Assert
        XCTAssertNil(Snappy.decompress(zeroOffset[...], limit: 100))
        XCTAssertNil(Snappy.decompress(beforeStart[...], limit: 100))
        XCTAssertNil(Snappy.decompress(overlong[...], limit: 100))
    }

    func testTableStopsDecompressingOnceItsBudgetIsSpent() {
        // Arrange: the index is read separately; the budget covers the data
        // blocks, and the one holding the key decompresses to well over 100 bytes.
        let filler = [UInt8](repeating: 0x61, count: 4000)
        let table = LevelDBWriter.table([
            [(LevelDBWriter.internalKey("bridgeDeviceId", sequence: 1), json("found") + filler)]
        ], compressed: true)

        // Act
        let withinBudget = LevelDB.tableEntry(for: key, in: table)
        let overBudget = LevelDB.tableEntry(for: key, in: table, budget: 100)

        // Assert
        XCTAssertEqual(withinBudget?.sequence, 1)
        XCTAssertNil(overBudget)
    }

    func testSnappyRefusesALengthOverTheLimitBeforeAllocating() {
        // Arrange: claims 2^40 bytes.
        let huge = LevelDBWriter.varint(1 << 40) + [0, 0x61]

        // Act / Assert
        XCTAssertNil(Snappy.decompress(huge[...], limit: LevelDB.maximumBlockSize))
    }

    /// A table cut short at any point is either unreadable or still right; it
    /// never yields a different value and never traps.
    func testEveryTruncationOfATableIsSafe() {
        // Arrange
        let table = LevelDBWriter.table([
            [(LevelDBWriter.internalKey("alpha", sequence: 1), json("a"))],
            [(LevelDBWriter.internalKey("bridgeDeviceId", sequence: 2), json("found"))]
        ], compressed: true)

        // Act / Assert
        for length in 0 ... table.count {
            let result = LevelDB.lookup(key: key, logs: [], tables: [Array(table.prefix(length))])
            XCTAssertTrue(result == .absent || result == .value(json("found")), "length \(length): \(result)")
        }
    }

    func testEveryTruncationOfALogIsSafe() {
        // Arrange
        let log = LevelDBWriter.log([
            LevelDBWriter.batch(sequence: 1, [.put("bridgeDeviceId", json("one"))]),
            LevelDBWriter.batch(sequence: 2, [.put("bridgeDeviceId", json("two"))])
        ])

        // Act / Assert
        for length in 0 ... log.count {
            let result = LevelDB.lookup(key: key, logs: [Array(log.prefix(length))], tables: [])
            XCTAssertTrue([.absent, .value(json("one")), .value(json("two"))].contains(result), "length \(length): \(result)")
        }
    }

    /// Bytes that are not LevelDB at all, and valid files with bytes flipped:
    /// the reader has to come back with an answer every time.
    func testRandomAndCorruptedInputNeverTraps() {
        // Arrange
        var generator = SplitMix64(state: 42)
        let table = LevelDBWriter.table([[(LevelDBWriter.internalKey("bridgeDeviceId", sequence: 2), json("found"))]], compressed: true)
        let log = LevelDBWriter.log([LevelDBWriter.batch(sequence: 1, [.put("bridgeDeviceId", json("one"))])])

        // Act / Assert: reaching the end without trapping is the assertion.
        for _ in 0 ..< 2000 {
            let length = Int.random(in: 0 ..< 600, using: &generator)
            let noise = (0 ..< length).map { _ in UInt8.random(in: 0 ... 255, using: &generator) }
            _ = LevelDB.lookup(key: key, logs: [noise], tables: [noise])
            _ = Snappy.decompress(noise[...], limit: 1 << 16)

            var damagedTable = table
            var damagedLog = log
            for _ in 0 ..< 3 {
                damagedTable[Int.random(in: 0 ..< damagedTable.count, using: &generator)] = UInt8.random(in: 0 ... 255, using: &generator)
                damagedLog[Int.random(in: 0 ..< damagedLog.count, using: &generator)] = UInt8.random(in: 0 ... 255, using: &generator)
            }
            _ = LevelDB.lookup(key: key, logs: [damagedLog], tables: [damagedTable])
        }
    }
}

final class ClaudeInChromeCatalogTests: XCTestCase {
    private static let storage = "/Local Extension Settings/" + ClaudeInChromeCatalog.extensionID

    /// An in-memory directory tree. `reads` counts file reads so a test can
    /// tell a cached answer from a fresh one.
    private final class FakeDisk: @unchecked Sendable {
        var directories: [String: [String]] = [:]
        var files: [String: [UInt8]] = [:]
        var modified: [String: Date] = [:]
        var unreadable: Set<String> = []
        var unlistable: Set<String> = []
        var listedSizes: [String: Int] = [:]
        var reads = 0
        var limits: [Int] = []

        var fileSystem: ClaudeInChromeCatalog.FileSystem {
            ClaudeInChromeCatalog.FileSystem(
                subdirectories: { [self] in unlistable.contains($0) ? nil : directories[$0] ?? [] },
                files: { [self] directory in
                    guard !unlistable.contains(directory), directories[directory] != nil || files.keys.contains(where: { $0.hasPrefix(directory + "/") }) else { return nil }
                    return files.keys.filter { URL(fileURLWithPath: $0).deletingLastPathComponent().path == directory }.map { path in
                        ClaudeInChromeCatalog.FileInfo(
                            name: URL(fileURLWithPath: path).lastPathComponent,
                            size: listedSizes[path] ?? files[path]!.count,
                            modified: modified[path] ?? Date(timeIntervalSince1970: 0)
                        )
                    }
                },
                contents: { [self] path, limit in
                    reads += 1
                    limits.append(limit)
                    return unreadable.contains(path) ? nil : files[path].map { Array($0.prefix(limit + 1)) }
                }
            )
        }

        func addProfile(_ profile: String, in root: String, deviceID: String?) {
            directories[root, default: []].append(profile)
            guard let deviceID else {
                directories[root + "/" + profile + "/Local Extension Settings"] = ["someotherextension"]
                return
            }
            directories[root + "/" + profile + "/Local Extension Settings"] = [ClaudeInChromeCatalog.extensionID]
            files[root + "/" + profile + storage + "/000003.log"] = LevelDBWriter.log([
                LevelDBWriter.batch(sequence: 1, [.put("bridgeDeviceId", json(deviceID))])
            ])
            files[root + "/" + profile + storage + "/LOG"] = Array("not a database".utf8)
        }
    }

    func testListsTheIDOfEveryProfileThatHasTheExtension() {
        // Arrange
        let disk = FakeDisk()
        disk.addProfile("Default", in: "/chrome", deviceID: "e973bce8-35e6-4bab-a020-4fb9fa990ea4")
        disk.addProfile("Profile 1", in: "/chrome", deviceID: nil)
        disk.addProfile("Profile 2", in: "/chrome", deviceID: "b92de35e-d1f0-45d8-83fa-0f3118ffbb9a")
        let catalog = ClaudeInChromeCatalog(fileSystem: disk.fileSystem)

        // Act
        let devices = catalog.devices(inUserDataDirectory: "/chrome")

        // Assert
        XCTAssertEqual(devices, [
            ClaudeInChromeDevice(profileDirectory: "Default", deviceID: "e973bce8-35e6-4bab-a020-4fb9fa990ea4"),
            ClaudeInChromeDevice(profileDirectory: "Profile 2", deviceID: "b92de35e-d1f0-45d8-83fa-0f3118ffbb9a")
        ])
    }

    func testMissingOrUnlistableDirectoriesGiveNoDevices() {
        // Arrange
        let catalog = ClaudeInChromeCatalog(fileSystem: FakeDisk().fileSystem)

        // Act / Assert
        XCTAssertEqual(catalog.devices(inUserDataDirectory: "/nowhere"), [])
        XCTAssertEqual(catalog.devices(inUserDataDirectory: nil), [])
    }

    func testStorageWithoutTheKeyGivesNoDevice() {
        // Arrange
        let disk = FakeDisk()
        disk.addProfile("Default", in: "/chrome", deviceID: "id")
        disk.files["/chrome/Default" + Self.storage + "/000003.log"] = LevelDBWriter.log([
            LevelDBWriter.batch(sequence: 1, [.put("somethingElse", json("x"))])
        ])

        // Act / Assert
        XCTAssertEqual(ClaudeInChromeCatalog(fileSystem: disk.fileSystem).devices(inUserDataDirectory: "/chrome"), [])
    }

    func testUnchangedFilesAreNotReadAgain() {
        // Arrange
        let disk = FakeDisk()
        disk.addProfile("Default", in: "/chrome", deviceID: "id-1")
        var clock = Date(timeIntervalSince1970: 1000)
        let catalog = ClaudeInChromeCatalog(recheckInterval: 30, now: { clock }, fileSystem: disk.fileSystem)
        _ = catalog.devices(inUserDataDirectory: "/chrome")
        let readsAfterFirst = disk.reads

        // Act
        clock += 10
        _ = catalog.devices(inUserDataDirectory: "/chrome")
        clock += 60
        let afterRecheck = catalog.devices(inUserDataDirectory: "/chrome")

        // Assert
        XCTAssertEqual(disk.reads, readsAfterFirst)
        XCTAssertEqual(afterRecheck.map(\.deviceID), ["id-1"])
    }

    func testChangedFilesAreReadAgainAfterTheInterval() {
        // Arrange
        let disk = FakeDisk()
        disk.addProfile("Default", in: "/chrome", deviceID: "id-1")
        var clock = Date(timeIntervalSince1970: 1000)
        let catalog = ClaudeInChromeCatalog(recheckInterval: 30, now: { clock }, fileSystem: disk.fileSystem)
        _ = catalog.devices(inUserDataDirectory: "/chrome")
        let path = "/chrome/Default" + Self.storage + "/000003.log"
        disk.files[path] = LevelDBWriter.log([LevelDBWriter.batch(sequence: 1, [.put("bridgeDeviceId", json("id-2"))])])
        disk.modified[path] = Date(timeIntervalSince1970: 2000)

        // Act
        clock += 10
        let beforeInterval = catalog.devices(inUserDataDirectory: "/chrome")
        clock += 60
        let afterInterval = catalog.devices(inUserDataDirectory: "/chrome")

        // Assert
        XCTAssertEqual(beforeInterval.map(\.deviceID), ["id-1"])
        XCTAssertEqual(afterInterval.map(\.deviceID), ["id-2"])
    }

    /// A compaction can delete a file between the listing and the read. The
    /// ID the last good read found stays up, and the next poll tries again
    /// instead of waiting out the interval.
    func testAFileThatVanishesMidReadKeepsThePreviousIDAndRetries() {
        // Arrange
        let disk = FakeDisk()
        disk.addProfile("Default", in: "/chrome", deviceID: "id-1")
        var clock = Date(timeIntervalSince1970: 1000)
        let catalog = ClaudeInChromeCatalog(recheckInterval: 30, now: { clock }, fileSystem: disk.fileSystem)
        _ = catalog.devices(inUserDataDirectory: "/chrome")
        let path = "/chrome/Default" + Self.storage + "/000003.log"
        disk.files[path] = LevelDBWriter.log([LevelDBWriter.batch(sequence: 2, [.put("bridgeDeviceId", json("id-2"))])])
        disk.modified[path] = Date(timeIntervalSince1970: 2000)
        disk.unreadable.insert(path)

        // Act
        clock += 60
        let duringCompaction = catalog.devices(inUserDataDirectory: "/chrome")
        let readsDuringCompaction = disk.reads
        disk.unreadable.remove(path)
        clock += 1
        let nextPoll = catalog.devices(inUserDataDirectory: "/chrome")
        let readsAfterRecovery = disk.reads
        clock += 1
        _ = catalog.devices(inUserDataDirectory: "/chrome")

        // Assert
        XCTAssertEqual(duringCompaction.map(\.deviceID), ["id-1"])
        XCTAssertEqual(nextPoll.map(\.deviceID), ["id-2"])
        XCTAssertGreaterThan(readsAfterRecovery, readsDuringCompaction, "the poll inside the interval read again")
        XCTAssertEqual(disk.reads, readsAfterRecovery, "settled again, so no further reads inside the interval")
    }

    func testAnUnlistableDirectoryKeepsThePreviousIDAndRetries() {
        // Arrange
        let disk = FakeDisk()
        disk.addProfile("Default", in: "/chrome", deviceID: "id-1")
        var clock = Date(timeIntervalSince1970: 1000)
        let catalog = ClaudeInChromeCatalog(recheckInterval: 30, now: { clock }, fileSystem: disk.fileSystem)
        _ = catalog.devices(inUserDataDirectory: "/chrome")
        let storage = "/chrome/Default" + Self.storage

        // Act
        clock += 60
        disk.unlistable = ["/chrome"]
        let rootUnlistable = catalog.devices(inUserDataDirectory: "/chrome")
        disk.unlistable = [storage]
        clock += 1
        let storageUnlistable = catalog.devices(inUserDataDirectory: "/chrome")
        disk.unlistable = ["/chrome/Default/Local Extension Settings"]
        clock += 1
        let settingsUnlistable = catalog.devices(inUserDataDirectory: "/chrome")
        disk.unlistable = []
        disk.files[storage + "/000003.log"] = LevelDBWriter.log([LevelDBWriter.batch(sequence: 2, [.put("bridgeDeviceId", json("id-2"))])])
        disk.modified[storage + "/000003.log"] = Date(timeIntervalSince1970: 2000)
        clock += 1
        let recovered = catalog.devices(inUserDataDirectory: "/chrome")

        // Assert
        XCTAssertEqual(rootUnlistable.map(\.deviceID), ["id-1"])
        XCTAssertEqual(storageUnlistable.map(\.deviceID), ["id-1"])
        XCTAssertEqual(settingsUnlistable.map(\.deviceID), ["id-1"])
        XCTAssertEqual(recovered.map(\.deviceID), ["id-2"], "an unsettled read is retried on the next poll")
    }

    /// The size in the listing can be stale by the time the file is read.
    func testAFileThatGrewPastTheLimitIsSkippedWithoutBeingReadWhole() {
        // Arrange
        let disk = FakeDisk()
        disk.addProfile("Default", in: "/chrome", deviceID: "id-1")
        let path = "/chrome/Default" + Self.storage + "/000003.log"
        let size = disk.files[path]!.count
        disk.files[path]! += [UInt8](repeating: 0, count: 1000)
        disk.listedSizes[path] = size

        // Act
        let devices = ClaudeInChromeCatalog(fileSystem: disk.fileSystem, maximumFileSize: size).devices(inUserDataDirectory: "/chrome")

        // Assert
        XCTAssertEqual(devices, [])
        XCTAssertEqual(disk.limits, [size])
    }

    /// A profile that had no ID yet is retried as well: a settings directory
    /// that could not be listed says nothing either way.
    func testUnlistableSettingsWithoutAPreviousIDIsRetriedOnTheNextPoll() {
        // Arrange
        let disk = FakeDisk()
        disk.addProfile("Default", in: "/chrome", deviceID: "id-1")
        disk.unlistable = ["/chrome/Default/Local Extension Settings"]
        var clock = Date(timeIntervalSince1970: 1000)
        let catalog = ClaudeInChromeCatalog(recheckInterval: 30, now: { clock }, fileSystem: disk.fileSystem)

        // Act
        let whileUnlistable = catalog.devices(inUserDataDirectory: "/chrome")
        disk.unlistable = []
        clock += 1
        let nextPoll = catalog.devices(inUserDataDirectory: "/chrome")

        // Assert
        XCTAssertEqual(whileUnlistable, [])
        XCTAssertEqual(nextPoll.map(\.deviceID), ["id-1"])
    }

    func testDeletedSettingsDirectoryDropsTheID() {
        // Arrange
        let disk = FakeDisk()
        disk.addProfile("Default", in: "/chrome", deviceID: "id-1")
        var clock = Date(timeIntervalSince1970: 1000)
        let catalog = ClaudeInChromeCatalog(recheckInterval: 30, now: { clock }, fileSystem: disk.fileSystem)
        _ = catalog.devices(inUserDataDirectory: "/chrome")

        // Act
        disk.directories["/chrome/Default/Local Extension Settings"] = nil
        clock += 60
        let devices = catalog.devices(inUserDataDirectory: "/chrome")

        // Assert
        XCTAssertEqual(devices, [])
    }

    /// Truncated since it was listed: what is left would parse to an older
    /// answer, so the read is retried rather than settled on.
    func testAFileShorterThanListedIsRetried() {
        // Arrange
        let disk = FakeDisk()
        disk.addProfile("Default", in: "/chrome", deviceID: "id-1")
        var clock = Date(timeIntervalSince1970: 1000)
        let catalog = ClaudeInChromeCatalog(recheckInterval: 30, now: { clock }, fileSystem: disk.fileSystem)
        _ = catalog.devices(inUserDataDirectory: "/chrome")
        let path = "/chrome/Default" + Self.storage + "/000003.log"
        disk.files[path] = LevelDBWriter.log([LevelDBWriter.batch(sequence: 2, [.put("bridgeDeviceId", json("id-2"))])])
        disk.listedSizes[path] = disk.files[path]!.count + 10
        disk.modified[path] = Date(timeIntervalSince1970: 2000)

        // Act
        clock += 60
        let truncated = catalog.devices(inUserDataDirectory: "/chrome")
        disk.listedSizes[path] = nil
        clock += 1
        let nextPoll = catalog.devices(inUserDataDirectory: "/chrome")

        // Assert
        XCTAssertEqual(truncated.map(\.deviceID), ["id-1"])
        XCTAssertEqual(nextPoll.map(\.deviceID), ["id-2"])
    }

    func testOversizedLimitIsClampedRatherThanOverflowing() {
        // Arrange
        let disk = FakeDisk()
        disk.addProfile("Default", in: "/chrome", deviceID: "id-1")

        // Act
        let devices = ClaudeInChromeCatalog(fileSystem: disk.fileSystem, maximumFileSize: Int.max).devices(inUserDataDirectory: "/chrome")

        // Assert
        XCTAssertEqual(devices.map(\.deviceID), ["id-1"])
        XCTAssertEqual(disk.limits, [1 << 30])
    }

    /// "Not there" and "could not list it" lead to different answers: the
    /// first drops an ID, the second keeps it.
    func testDiskListingTellsMissingFromUnlistable() throws {
        // Arrange
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Default"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("plain-file")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ClaudeInChromeCatalog.FileSystem.disk

        // Act / Assert
        XCTAssertEqual(disk.subdirectories(root.path), ["Default"])
        XCTAssertEqual(disk.subdirectories(root.appendingPathComponent("missing").path), [])
        XCTAssertNil(disk.subdirectories(file.path))
        XCTAssertEqual(disk.contents(file.path, 10), Array("x".utf8))
        XCTAssertNil(disk.contents(root.path, 10), "a directory is not read as a file")
        XCTAssertNil(disk.contents(root.appendingPathComponent("missing").path, 10))
    }

    func testDiskReadOfAFIFOReturnsInsteadOfBlocking() throws {
        // Arrange
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        defer { unlink(path) }

        // Act / Assert: with no writer, a blocking open would never return.
        XCTAssertNil(ClaudeInChromeCatalog.FileSystem.disk.contents(path, 10))
    }

    func testOnlyShortSingleLineStringsAreTakenAsAnID() {
        // Act / Assert
        XCTAssertEqual(ClaudeInChromeCatalog.deviceID(fromStoredValue: json("e973bce8-35e6")), "e973bce8-35e6")
        XCTAssertNil(ClaudeInChromeCatalog.deviceID(fromStoredValue: Array("{\"id\":1}".utf8)))
        XCTAssertNil(ClaudeInChromeCatalog.deviceID(fromStoredValue: Array("42".utf8)))
        XCTAssertNil(ClaudeInChromeCatalog.deviceID(fromStoredValue: json("")))
        XCTAssertNil(ClaudeInChromeCatalog.deviceID(fromStoredValue: Array("\"a\\nb\"".utf8)))
        XCTAssertNil(ClaudeInChromeCatalog.deviceID(fromStoredValue: json(String(repeating: "x", count: 200))))
        XCTAssertNil(ClaudeInChromeCatalog.deviceID(fromStoredValue: json("a" + String(repeating: "\u{301}", count: 100))), "one character, 201 bytes")
        XCTAssertNil(ClaudeInChromeCatalog.deviceID(fromStoredValue: [0xff, 0xfe]))
    }

    func testInstanceListsItsOwnProfileFirstWithProfileNames() {
        // Arrange
        let disk = FakeDisk()
        disk.addProfile("Default", in: "/tmp/agent", deviceID: "id-default")
        disk.addProfile("Profile 3", in: "/tmp/agent", deviceID: "id-three")
        let localState = #"{"profile":{"info_cache":{"Default":{"name":"Home"},"Profile 3":{"name":"Work"}}}}"#
        let inspector = ChromeInspector(
            catalog: ChromeProfileCatalog { _ in Data(localState.utf8) },
            claudeInChrome: ClaudeInChromeCatalog(fileSystem: disk.fileSystem),
            listeners: { _ in [] }
        )
        let browser = ProcessFinding(
            process: ProcessSnapshot(
                identity: ProcessIdentity(pid: 500, startTime: Date(timeIntervalSince1970: 1)),
                parentPID: 1,
                name: "Google Chrome",
                executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                arguments: ["chrome", "--user-data-dir=/tmp/agent", "--profile-directory=Profile 3"],
                totalCPUTimeNanoseconds: 0,
                residentMemoryBytes: 0
            ),
            cpuPercent: 0, isOrphanChromeHelper: false, score: 0, reasons: []
        )

        // Act
        let devices = inspector.instances(from: [browser]).first?.claudeInChromeDevices

        // Assert
        XCTAssertEqual(devices, [
            ClaudeInChromeDevice(profileDirectory: "Profile 3", profileName: "Work", deviceID: "id-three"),
            ClaudeInChromeDevice(profileDirectory: "Default", profileName: "Home", deviceID: "id-default")
        ])
        XCTAssertEqual(devices?.first?.menuText, "id-three — Work")
    }
}

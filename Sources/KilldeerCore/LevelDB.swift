import Foundation

/// A read-only lookup of one key in a LevelDB directory that another process
/// owns and is writing to.
///
/// The browser holds the database's lock, so the files are read directly
/// instead of through the LevelDB library. Every input is treated as hostile:
/// a file can be half-written, replaced by a compaction between listing and
/// reading, or simply not what it claims to be. Any structure that does not
/// check out is skipped, never trusted, and no path through here can trap.
///
/// The MANIFEST is not read. Every log and table in the directory is scanned
/// and the entry with the highest sequence number wins. That matches the live
/// database except in the moment between a compaction that drops a deleted
/// key and the removal of the tables it replaced, when the old value can show
/// again; the next read after the old tables are gone corrects it.
enum LevelDB {
    enum Lookup: Equatable {
        case value([UInt8])
        /// The newest entry for the key is a deletion.
        case deleted
        case absent
    }

    struct Entry: Equatable {
        let sequence: UInt64
        /// nil for a deletion.
        let value: [UInt8]?
    }

    /// A decompressed block or a value larger than this is not something the
    /// extension stores, and is refused rather than allocated.
    static let maximumBlockSize = 64 << 20
    /// What one table may decompress in all. A table of the extension's size
    /// comes to a few megabytes; this stops a damaged one made of many blocks
    /// that each claim a large size from holding up the scan.
    static let maximumDecompressedPerTable = 256 << 20
    /// Sequence numbers are 56 bits; the low byte of a stored tag is the type.
    static let maximumSequence: UInt64 = (1 << 56) - 1

    /// Only the newest candidate is ever kept, so memory stays bounded by
    /// one value however many times a damaged file repeats the key.
    static func newer(_ a: Entry?, _ b: Entry?) -> Entry? {
        guard let a else { return b }
        guard let b else { return a }
        return b.sequence > a.sequence ? b : a
    }

    static func lookup(_ entry: Entry?) -> Lookup {
        guard let entry else { return .absent }
        return entry.value.map(Lookup.value) ?? .deleted
    }

    static func lookup(key: [UInt8], logs: [[UInt8]], tables: [[UInt8]]) -> Lookup {
        var newest: Entry?
        for log in logs { newest = newer(newest, logEntry(for: key, in: log)) }
        for table in tables { newest = newer(newest, tableEntry(for: key, in: table)) }
        return lookup(newest)
    }

    // MARK: Log files

    private static let logBlockSize = 32768
    private static let logHeaderSize = 7

    static func logEntry(for key: [UInt8], in file: [UInt8]) -> Entry? {
        var newest: Entry?
        forEachLogRecord(in: file) { newest = newer(newest, batchEntry(for: key, in: $0)) }
        return newest
    }

    static func logRecords(in file: [UInt8]) -> [[UInt8]] {
        var records: [[UInt8]] = []
        forEachLogRecord(in: file) { records.append($0) }
        return records
    }

    /// Reassembles the records of a log file the way LevelDB's own reader
    /// does: a header that does not check out drops the rest of its block and
    /// any record being assembled, and reading resumes at the next block. The
    /// browser appends to the newest log while it runs, so its last record is
    /// routinely incomplete, and one damaged block must not hide later ones.
    static func forEachLogRecord(in file: [UInt8], _ body: ([UInt8]) -> Void) {
        var fragment: [UInt8]?
        var blockStart = 0
        while blockStart < file.count {
            let blockEnd = min(blockStart + logBlockSize, file.count)
            var position = blockStart
            while blockEnd - position >= logHeaderSize {
                let storedCRC = readUInt32(file, at: position)
                let length = Int(file[position + 4]) | Int(file[position + 5]) << 8
                let type = file[position + 6]
                let dataStart = position + logHeaderSize
                // A zero header is space the writer preallocated and has not
                // reached yet; the rest of the block is the same.
                // LevelDB's reader treats it as a bad record, which also ends
                // any record being assembled.
                if type == 0 && length == 0 {
                    fragment = nil
                    break
                }
                guard length <= blockEnd - dataStart else {
                    fragment = nil
                    break
                }
                let data = file[dataStart ..< dataStart + length]
                guard unmaskCRC(storedCRC) == CRC32C.checksum(type: type, data) else {
                    fragment = nil
                    break
                }
                position = dataStart + length
                switch type {
                case 1:
                    fragment = nil
                    body(Array(data))
                case 2:
                    fragment = Array(data)
                case 3:
                    fragment?.append(contentsOf: data)
                case 4:
                    if var whole = fragment {
                        whole.append(contentsOf: data)
                        body(whole)
                    }
                    fragment = nil
                default:
                    fragment = nil
                }
                if let partial = fragment, partial.count > maximumBlockSize { fragment = nil }
            }
            blockStart += logBlockSize
        }
    }

    /// The last entry of one write batch that sets or deletes `key`, which is
    /// the one with the highest sequence number. A batch that does not parse
    /// exactly to its end is dropped whole: half of a batch, or one with bytes
    /// its count does not account for, is not a state the database was ever in.
    static func batchEntry(for key: [UInt8], in batch: [UInt8]) -> Entry? {
        var reader = ByteReader(batch)
        guard let sequence = reader.uint64(), let count = reader.uint32(),
              sequence <= maximumSequence,
              UInt64(count) <= maximumSequence - sequence + 1
        else { return nil }
        // Located first and copied once at the end, so a batch repeating the
        // key holds no more than one value.
        var last: (index: UInt64, value: ArraySlice<UInt8>?)?
        for index in 0 ..< UInt64(count) {
            guard let tag = reader.byte(), let entryKey = reader.lengthPrefixed() else { return nil }
            switch tag {
            case 1:
                guard let value = reader.lengthPrefixed() else { return nil }
                if entryKey.elementsEqual(key) { last = (index, value) }
            case 0:
                if entryKey.elementsEqual(key) { last = (index, nil) }
            default:
                return nil
            }
        }
        guard reader.isAtEnd, let last else { return nil }
        return Entry(sequence: sequence + last.index, value: last.value.map(Array.init))
    }

    // MARK: Table files

    private static let footerSize = 48
    private static let tableMagic: UInt64 = 0xdb47_7524_8b80_fb57
    private static let blockTrailerSize = 5

    static func tableEntry(for key: [UInt8], in file: [UInt8], budget: Int = maximumDecompressedPerTable) -> Entry? {
        guard file.count >= footerSize else { return nil }
        var footer = ByteReader(file[(file.count - footerSize)...])
        guard footer.blockHandle() != nil,
              let indexHandle = footer.blockHandle(),
              readUInt64(file, at: file.count - 8) == tableMagic,
              let index = block(at: indexHandle, in: file)
        else { return nil }

        // Each index entry is a key at or past the last key of its data block
        // and before the first key of the next, so only the blocks whose range
        // can hold `key` are decompressed. Compared on user keys alone, which
        // can include a neighbour but never skip the block that matters.
        var newest: Entry?
        // Whether the previous separator's user key sorts after `key`; only
        // that, not a copy of the separator, is carried to the next entry.
        var previousIsPastKey = false
        // Data blocks are laid out in key order, so a handle that does not
        // move forward is damage and would only read a block a second time.
        var nextBlockOffset = 0
        var budget = budget
        forEachBlockEntry(index) { separator, handleBytes in
            if previousIsPastKey { return false }
            guard let upper = userKey(separator) else { return true }
            previousIsPastKey = Self.precedes(key, upper)
            if Self.precedes(upper, key) { return true }
            var handleReader = ByteReader(handleBytes)
            guard let handle = handleReader.blockHandle(),
                  handle.offset >= nextBlockOffset,
                  let end = blockEnd(of: handle, in: file)
            else { return true }
            // Advanced whether or not the block reads, so no stretch of the
            // file is checksummed twice however often the index names it.
            nextBlockOffset = end
            // Charged before decompressing and whether or not it succeeds: a
            // block that fails at its last byte has cost as much as one that
            // reads.
            guard let cost = declaredSize(of: handle, in: file), cost <= budget else { return false }
            budget -= cost
            guard let data = block(at: handle, in: file, limit: cost) else { return true }
            forEachBlockEntry(data) { internalKey, value in
                // A length check first, so a block of long keys costs nothing
                // to step over.
                guard internalKey.count == key.count + 8,
                      let parsed = parseInternalKey(internalKey), parsed.user.elementsEqual(key)
                else { return true }
                guard parsed.type <= 1, newest.map({ parsed.sequence > $0.sequence }) ?? true else { return true }
                newest = Entry(sequence: parsed.sequence, value: parsed.type == 1 ? Array(value) : nil)
                return true
            }
            return true
        }
        return newest
    }

    /// Bytewise order of a separator against the short key being looked up.
    /// Only the first `key.count + 1` bytes of the separator can decide it,
    /// so a damaged block of very long separators costs no more to step over
    /// than a block of short ones.
    private static func precedes(_ separator: ArraySlice<UInt8>, _ key: [UInt8]) -> Bool {
        separator.prefix(key.count + 1).lexicographicallyPrecedes(key)
    }

    private static func precedes(_ key: [UInt8], _ separator: ArraySlice<UInt8>) -> Bool {
        key.lexicographicallyPrecedes(separator.prefix(key.count + 1))
    }

    struct BlockHandle: Equatable {
        let offset: Int
        let size: Int
    }

    /// A block's contents, once its checksum has been verified and it has
    /// been decompressed. The checksum covers the stored bytes and the
    /// compression type, so a flipped bit in a value or sequence number is
    /// caught here rather than read as a different ID.
    /// Where a block and its trailer end, or nil if they do not fit the file.
    static func blockEnd(of handle: BlockHandle, in file: [UInt8]) -> Int? {
        guard handle.offset <= file.count,
              handle.size <= file.count - handle.offset,
              blockTrailerSize <= file.count - handle.offset - handle.size
        else { return nil }
        return handle.offset + handle.size + blockTrailerSize
    }

    /// The size a block will have once read: its stored size, or for a
    /// Snappy block the length its header claims.
    static func declaredSize(of handle: BlockHandle, in file: [UInt8]) -> Int? {
        guard blockEnd(of: handle, in: file) != nil else { return nil }
        let contentsEnd = handle.offset + handle.size
        guard file[contentsEnd] == 1 else { return handle.size }
        var reader = ByteReader(file[handle.offset ..< contentsEnd])
        return reader.varint()
    }

    static func block(at handle: BlockHandle, in file: [UInt8], limit: Int = maximumBlockSize) -> [UInt8]? {
        guard blockEnd(of: handle, in: file) != nil else { return nil }
        let limit = min(limit, maximumBlockSize)
        let contentsEnd = handle.offset + handle.size
        let stored = file[handle.offset ..< contentsEnd + 1]
        guard unmaskCRC(readUInt32(file, at: contentsEnd + 1)) == CRC32C.checksum(stored) else { return nil }
        let contents = file[handle.offset ..< contentsEnd]
        switch file[contentsEnd] {
        case 0: return contents.count <= limit ? Array(contents) : nil
        case 1: return Snappy.decompress(contents, limit: limit)
        // zstd, or a type newer than this reader. Unreadable rather than wrong.
        default: return nil
        }
    }

    /// Calls `body` with each key/value pair of a block, in order, until it
    /// returns false or an entry does not parse. Nothing is retained between
    /// entries but the current key: a block of long keys that share a prefix
    /// would otherwise hold a full copy of each. Rebuilding the key removes
    /// and appends no more bytes than the block holds, so a whole block costs
    /// time in proportion to its size.
    static func forEachBlockEntry(_ block: [UInt8], _ body: (ArraySlice<UInt8>, ArraySlice<UInt8>) -> Bool) {
        guard block.count >= 4 else { return }
        let restartCount = Int(readUInt32(block, at: block.count - 4))
        guard restartCount <= (block.count - 4) / 4 else { return }
        let entriesEnd = block.count - 4 - restartCount * 4
        var reader = ByteReader(block[..<entriesEnd])
        var key: [UInt8] = []
        while !reader.isAtEnd {
            guard let shared = reader.varint(), let unshared = reader.varint(), let valueLength = reader.varint(),
                  shared <= key.count,
                  let suffix = reader.bytes(unshared),
                  let value = reader.bytes(valueLength)
            else { return }
            key.removeSubrange(shared...)
            key.append(contentsOf: suffix)
            guard body(key[...], value) else { return }
        }
    }

    static func blockEntries(_ block: [UInt8]) -> [([UInt8], [UInt8])] {
        var entries: [([UInt8], [UInt8])] = []
        forEachBlockEntry(block) { key, value in
            entries.append((Array(key), Array(value)))
            return true
        }
        return entries
    }

    static func userKey(_ internalKey: ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
        guard internalKey.count >= 8 else { return nil }
        return internalKey[..<(internalKey.endIndex - 8)]
    }

    static func parseInternalKey(_ internalKey: ArraySlice<UInt8>) -> (user: ArraySlice<UInt8>, sequence: UInt64, type: UInt8)? {
        guard let user = userKey(internalKey) else { return nil }
        var reader = ByteReader(internalKey[(internalKey.endIndex - 8)...])
        guard let tag = reader.uint64() else { return nil }
        return (user, tag >> 8, UInt8(truncatingIfNeeded: tag))
    }

    // MARK: Helpers

    /// Callers have already checked that four bytes are there.
    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0 ..< 4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        (0 ..< 8).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << (8 * $1) }
    }

    private static func unmaskCRC(_ masked: UInt32) -> UInt32 {
        let rotated = masked &- 0xa282_ead8
        return (rotated >> 17) | (rotated << 15)
    }
}

/// Bounds-checked little-endian reads. Each returns nil instead of reading
/// past the end, and leaves the position where it was when it does.
struct ByteReader {
    private let bytes: ArraySlice<UInt8>
    private var position: Int

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        self.position = bytes.startIndex
    }

    init(_ bytes: [UInt8]) {
        self.init(bytes[...])
    }

    var isAtEnd: Bool { position >= bytes.endIndex }

    mutating func byte() -> UInt8? {
        guard position < bytes.endIndex else { return nil }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func bytes(_ count: Int) -> ArraySlice<UInt8>? {
        guard count >= 0, count <= bytes.endIndex - position else { return nil }
        defer { position += count }
        return bytes[position ..< position + count]
    }

    mutating func uint32() -> UInt32? {
        bytes(4).map { $0.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) } }
    }

    mutating func uint64() -> UInt64? {
        bytes(8).map { $0.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) } }
    }

    /// A LEB128 varint of at most 64 bits, as an `Int`. A value that does not
    /// fit, or that runs past the end, is nil.
    mutating func varint() -> Int? {
        let start = position
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while shift < 64, let next = byte() {
            // The tenth byte has room for one bit; more would be dropped by
            // the shift and the value read as something smaller.
            if shift == 63 && next > 1 { break }
            result |= UInt64(next & 0x7f) << shift
            if next & 0x80 == 0 {
                guard result <= UInt64(Int.max) else { break }
                return Int(result)
            }
            shift += 7
        }
        position = start
        return nil
    }

    mutating func lengthPrefixed() -> ArraySlice<UInt8>? {
        let start = position
        guard let length = varint(), let data = bytes(length) else {
            position = start
            return nil
        }
        return data
    }

    mutating func blockHandle() -> LevelDB.BlockHandle? {
        let start = position
        guard let offset = varint(), let size = varint() else {
            position = start
            return nil
        }
        return LevelDB.BlockHandle(offset: offset, size: size)
    }
}

enum Snappy {
    /// Decompresses a raw Snappy block, or returns nil if it is malformed or
    /// would come out longer than `limit`.
    static func decompress(_ input: ArraySlice<UInt8>, limit: Int) -> [UInt8]? {
        var reader = ByteReader(input)
        // Every element of a Snappy stream is at least one byte and produces
        // at most 64, so a claimed length beyond that ratio is damage, and is
        // refused before anything is allocated for it.
        guard let length = reader.varint(), length <= limit, length / 64 <= input.count else { return nil }
        var output: [UInt8] = []
        output.reserveCapacity(length)
        while let tag = reader.byte() {
            let copyLength: Int
            let offset: Int
            switch tag & 3 {
            case 0:
                var literalLength = Int(tag >> 2)
                if literalLength >= 60 {
                    guard let extra = reader.bytes(literalLength - 59) else { return nil }
                    literalLength = extra.enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
                }
                literalLength += 1
                guard literalLength <= length - output.count, let literal = reader.bytes(literalLength) else { return nil }
                output.append(contentsOf: literal)
                continue
            case 1:
                guard let low = reader.byte() else { return nil }
                copyLength = Int((tag >> 2) & 7) + 4
                offset = Int(tag >> 5) << 8 | Int(low)
            case 2:
                guard let bytes = reader.bytes(2) else { return nil }
                copyLength = Int(tag >> 2) + 1
                offset = Int(bytes[bytes.startIndex]) | Int(bytes[bytes.startIndex + 1]) << 8
            default:
                guard let value = reader.uint32() else { return nil }
                copyLength = Int(tag >> 2) + 1
                offset = Int(value)
            }
            guard offset > 0, offset <= output.count, copyLength <= length - output.count else { return nil }
            // Byte by byte: a copy may overlap the bytes it is producing.
            for _ in 0 ..< copyLength { output.append(output[output.count - offset]) }
        }
        return output.count == length ? output : nil
    }
}

/// CRC-32C (Castagnoli), which LevelDB uses for log records and table blocks.
enum CRC32C {
    private static let table: [UInt32] = (0 ..< 256).map { index in
        (0 ..< 8).reduce(UInt32(index)) { crc, _ in crc & 1 == 1 ? (crc >> 1) ^ 0x82f6_3b78 : crc >> 1 }
    }

    static func checksum<C: Collection>(_ bytes: C, seed: UInt32 = 0) -> UInt32 where C.Element == UInt8 {
        var crc = ~seed
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
        }
        return ~crc
    }

    /// A log record's checksum covers its type byte, then its data.
    static func checksum(type: UInt8, _ data: ArraySlice<UInt8>) -> UInt32 {
        checksum(data, seed: checksum([type]))
    }

    static func masked(_ crc: UInt32) -> UInt32 {
        ((crc >> 15) | (crc << 17)) &+ 0xa282_ead8
    }
}

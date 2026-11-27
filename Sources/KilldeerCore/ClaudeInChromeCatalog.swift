import Foundation

/// The ID the Claude in Chrome extension gives one browser profile. Claude
/// Code lists connected browsers by this ID, and several Chrome windows (or
/// several machines) on one account look alike there. Seeing the ID beside
/// a running instance says which one is which.
public struct ClaudeInChromeDevice: Equatable, Sendable {
    public let profileDirectory: String
    /// The name from the browser's profile switcher, when `Local State` could
    /// be read.
    public let profileName: String?
    public let deviceID: String

    public init(profileDirectory: String, profileName: String? = nil, deviceID: String) {
        self.profileDirectory = profileDirectory
        self.profileName = profileName
        self.deviceID = deviceID
    }

    func named(by profiles: [String: ChromeProfile]?) -> ClaudeInChromeDevice {
        ClaudeInChromeDevice(profileDirectory: profileDirectory, profileName: profiles?[profileDirectory]?.name, deviceID: deviceID)
    }
}

/// Reads the Claude in Chrome device ID out of each profile's extension
/// storage.
///
/// The ID lives in `chrome.storage.local`, which Chromium keeps as a LevelDB
/// under `<profile>/Local Extension Settings/<extension ID>`. That layout and
/// the key name belong to the extension, not to any published interface, so
/// everything here is best effort: a missing directory, an unreadable file or
/// a format this reader does not know all come out as "no ID" for that
/// profile, never as an error the caller has to handle.
public final class ClaudeInChromeCatalog: @unchecked Sendable {
    public static let extensionID = "fcoeoabgfenejglbffodgkkbkcdhcgfn"
    static let storageKey = Array("bridgeDeviceId".utf8)

    /// A file this large is not extension storage the reader can use, and
    /// reading it on a poll would cost more than the ID is worth.
    public static let defaultMaximumFileSize = 64 << 20

    public struct FileInfo: Equatable, Sendable {
        public let name: String
        public let size: Int
        public let modified: Date

        public init(name: String, size: Int, modified: Date) {
            self.name = name
            self.size = size
            self.modified = modified
        }
    }

    /// The file system operations the catalog needs, so tests can supply a
    /// directory tree without touching the disk.
    public struct FileSystem: Sendable {
        /// The subdirectories of a directory: empty when it does not exist,
        /// nil when it exists and cannot be listed.
        public var subdirectories: @Sendable (String) -> [String]?
        /// The regular files of a directory, or nil when it or any entry's
        /// attributes cannot be read: a listing missing a file would compare
        /// as a change and read as if that file did not exist.
        public var files: @Sendable (String) -> [FileInfo]?
        /// At most `limit + 1` bytes of a file, so a file that grew past the
        /// limit after it was listed shows as too long without being read
        /// whole. nil when it cannot be read.
        public var contents: @Sendable (_ path: String, _ limit: Int) -> [UInt8]?

        public init(
            subdirectories: @escaping @Sendable (String) -> [String]?,
            files: @escaping @Sendable (String) -> [FileInfo]?,
            contents: @escaping @Sendable (_ path: String, _ limit: Int) -> [UInt8]?
        ) {
            self.subdirectories = subdirectories
            self.files = files
            self.contents = contents
        }

        public static let disk = FileSystem(
            subdirectories: { path in
                let url = URL(fileURLWithPath: path, isDirectory: true)
                let entries: [URL]
                do {
                    entries = try FileManager.default.contentsOfDirectory(
                        at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                    )
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                    return []
                } catch {
                    return nil
                }
                // An entry whose type cannot be read fails the whole listing,
                // as in `files`: dropping it would read as that profile or
                // extension being gone.
                var directories: [String] = []
                for entry in entries {
                    guard let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory else { return nil }
                    if isDirectory { directories.append(entry.lastPathComponent) }
                }
                return directories
            },
            files: { path in
                let url = URL(fileURLWithPath: path, isDirectory: true)
                let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
                guard let entries = try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
                ) else { return nil }
                var files: [FileInfo] = []
                for entry in entries {
                    guard let values = try? entry.resourceValues(forKeys: keys),
                          let isRegularFile = values.isRegularFile,
                          let size = values.fileSize,
                          let modified = values.contentModificationDate
                    else { return nil }
                    if isRegularFile { files.append(FileInfo(name: entry.lastPathComponent, size: size, modified: modified)) }
                }
                return files
            },
            contents: { path, limit in
                // Read through a descriptor rather than memory-mapped: the
                // browser can truncate or replace a file while it is being
                // read, and a mapped page that vanishes is a crash rather than
                // an error. Opened without blocking and checked to be a regular
                // file on the descriptor itself, because the path can have been
                // replaced since it was listed, and opening a FIFO with no
                // writer would hang the scan.
                let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
                guard descriptor >= 0 else { return nil }
                var status = stat()
                guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
                    close(descriptor)
                    return nil
                }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                do {
                    let limit = min(max(limit, 0), Int.max - 1)
                    return [UInt8](try handle.read(upToCount: limit + 1) ?? Data())
                } catch {
                    return nil
                }
            }
        )
    }

    private enum ProfileRead {
        case found(String)
        case none
        /// A file listed a moment ago could not be read, which is what a
        /// compaction in progress looks like. Not the same as "no ID".
        case unreadable
    }

    private struct Entry {
        var devices: [ClaudeInChromeDevice]
        /// nil after a read that did not settle, so that no listing matches it
        /// and the next poll reads again.
        var signature: [String: [FileInfo]]?
        var checkedAt: Date
    }

    private var cache: [String: Entry] = [:]
    private let lock = NSLock()
    private let fileSystem: FileSystem
    private let now: () -> Date
    /// Listing every profile's storage on every poll is cheap, but the menu
    /// bar app polls every few seconds and the ID almost never changes.
    private let recheckInterval: TimeInterval
    private let maximumFileSize: Int

    public init(
        recheckInterval: TimeInterval = 30,
        now: @escaping () -> Date = Date.init,
        fileSystem: FileSystem = .disk,
        maximumFileSize: Int = ClaudeInChromeCatalog.defaultMaximumFileSize
    ) {
        self.recheckInterval = recheckInterval
        // Bounded so that `limit + 1` in a read cannot overflow, and so a
        // caller cannot ask for more than any file here could need.
        self.maximumFileSize = min(max(maximumFileSize, 0), 1 << 30)
        self.now = now
        self.fileSystem = fileSystem
    }

    /// The profiles of a user-data-dir that have a Claude in Chrome ID,
    /// ordered by profile directory. Empty when there are none or nothing
    /// could be read.
    public func devices(inUserDataDirectory directory: String?) -> [ClaudeInChromeDevice] {
        guard let directory else { return [] }
        lock.lock()
        defer { lock.unlock() }

        let previous = cache[directory]
        if let previous, now().timeIntervalSince(previous.checkedAt) < recheckInterval {
            return previous.devices
        }

        // The user-data-dir itself could not be listed. Not the same as
        // having no profiles, so whatever was shown stays and the next poll
        // tries again.
        guard let (storages, unlistedSettings) = storageDirectories(in: directory) else { return previous?.devices ?? [] }
        // Only the file listings, which is all that can tell whether anything
        // changed since the last read without reading the files themselves.
        var signature: [String: [FileInfo]] = [:]
        var unlisted: Set<String> = []
        for storage in storages {
            if let files = fileSystem.files(storage.path) {
                signature[storage.profile] = files.sorted { $0.name < $1.name }
            } else {
                unlisted.insert(storage.profile)
            }
        }
        // A profile whose settings directory exists but cannot be listed
        // keeps the ID it had, as a file that cannot be read does.
        let kept = previous?.devices.filter { unlistedSettings.contains($0.profileDirectory) } ?? []
        if unlisted.isEmpty, unlistedSettings.isEmpty, let previous, previous.signature == signature {
            cache[directory]?.checkedAt = now()
            return previous.devices
        }

        var devices = kept
        var settled = unlistedSettings.isEmpty
        for storage in storages {
            let result = signature[storage.profile].map { read(storage.path, files: $0) } ?? .unreadable
            switch result {
            case let .found(id):
                devices.append(ClaudeInChromeDevice(profileDirectory: storage.profile, deviceID: id))
            case .none:
                break
            case .unreadable:
                // Keep what the last good read said for this profile, and do
                // not remember this listing, so the next poll tries again
                // rather than waiting out the interval with the ID missing.
                settled = false
                if let kept = previous?.devices.first(where: { $0.profileDirectory == storage.profile }) {
                    devices.append(kept)
                }
            }
        }
        devices.sort { $0.profileDirectory < $1.profileDirectory }
        cache[directory] = Entry(
            devices: devices,
            signature: settled ? signature : nil,
            checkedAt: settled ? now() : .distantPast
        )
        return devices
    }

    /// The profiles with the extension's storage, and the profiles whose
    /// `Local Extension Settings` could not be listed. nil when the
    /// user-data-dir itself cannot be listed.
    private func storageDirectories(in userDataDirectory: String) -> ([(profile: String, path: String)], Set<String>)? {
        guard let profiles = fileSystem.subdirectories(userDataDirectory) else { return nil }
        var storages: [(profile: String, path: String)] = []
        var unlisted: Set<String> = []
        for profile in profiles.sorted() {
            let settings = userDataDirectory + "/" + profile + "/Local Extension Settings"
            guard let extensions = fileSystem.subdirectories(settings) else {
                unlisted.insert(profile)
                continue
            }
            if extensions.contains(Self.extensionID) { storages.append((profile, settings + "/" + Self.extensionID)) }
        }
        return (storages, unlisted)
    }

    /// One file at a time, keeping only the entries for the key, so memory
    /// use is bounded by the largest file rather than by the whole database.
    private func read(_ storage: String, files: [FileInfo]) -> ProfileRead {
        var newest: LevelDB.Entry?
        for file in files {
            let isLog = file.name.hasSuffix(".log") && file.name != "LOG"
            let isTable = file.name.hasSuffix(".ldb") || file.name.hasSuffix(".sst")
            guard isLog || isTable, file.size <= maximumFileSize else { continue }
            guard let contents = fileSystem.contents(storage + "/" + file.name, maximumFileSize) else { return .unreadable }
            // Grew past the limit since it was listed; skipped like one that
            // was already too large.
            guard contents.count <= maximumFileSize else { continue }
            // Shorter than listed: truncated or replaced since. Reading what
            // is left would settle on a partial answer until the files next
            // change, so the whole read is tried again instead. A log only
            // ever grows, so longer is normal.
            guard contents.count >= file.size else { return .unreadable }
            newest = LevelDB.newer(newest, isLog
                ? LevelDB.logEntry(for: Self.storageKey, in: contents)
                : LevelDB.tableEntry(for: Self.storageKey, in: contents))
        }
        guard case let .value(bytes) = LevelDB.lookup(newest),
              let id = Self.deviceID(fromStoredValue: bytes)
        else { return .none }
        return .found(id)
    }

    /// `chrome.storage` keeps each value as JSON. Anything other than a short
    /// single-line string is not an ID this menu should print.
    static func deviceID(fromStoredValue bytes: [UInt8]) -> String? {
        // Bounded in bytes before parsing and after: a count of characters
        // lets a long run of combining marks through as one.
        guard bytes.count <= 1024, let string = (try? JSONSerialization.jsonObject(with: Data(bytes), options: .fragmentsAllowed)) as? String else {
            return nil
        }
        let id = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.utf8.count <= 128, id.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return id
    }
}

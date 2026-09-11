import Foundation

public struct ChromeProfile: Equatable, Sendable {
    /// The name shown in the browser's own profile switcher.
    public let name: String
    /// The signed-in account, or nil when the profile is local. Chrome writes
    /// an empty string rather than dropping the key for a local profile, so an
    /// empty value has to be read as "not signed in".
    public let accountName: String?

    public init(name: String, accountName: String?) {
        self.name = name
        self.accountName = accountName
    }
}

/// Reads profile display names out of a user-data-dir's `Local State`.
///
/// `Local State` is a few hundred kilobytes of JSON that the browser rewrites
/// while it runs, so a read can land on a half-written file. Every failure is
/// swallowed and reported as "no profile information": the command still has
/// something useful to say without it, and this is a strictly read-only,
/// best-effort lookup.
public final class ChromeProfileCatalog: @unchecked Sendable {
    struct LocalState {
        var profiles: [String: ChromeProfile]
        /// The profile the browser reopens when no `--profile-directory` is
        /// given. Absent in browsers that never wrote the key, such as Vivaldi.
        var lastUsed: String?

        var isEmpty: Bool { profiles.isEmpty && lastUsed == nil }
    }

    private var cache: [String: (state: LocalState, readAt: Date)] = [:]
    private let lock = NSLock()
    private let fileContents: (String) -> Data?
    private let now: () -> Date
    /// The menu bar app polls every few seconds and this file runs to several
    /// hundred kilobytes, so it is not re-read on every poll. Caching it for
    /// the life of the process instead would mean a profile rename never
    /// appears, so the entry is kept only briefly.
    private let cacheLifetime: TimeInterval

    public init(
        cacheLifetime: TimeInterval = 30,
        now: @escaping () -> Date = Date.init,
        fileContents: @escaping (String) -> Data? = { path in
            try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        }
    ) {
        self.cacheLifetime = cacheLifetime
        self.now = now
        self.fileContents = fileContents
    }

    public func profile(userDataDirectory: String?, profileDirectory: String?) -> ChromeProfile? {
        guard let userDataDirectory, let profileDirectory else { return nil }
        return localState(inUserDataDirectory: userDataDirectory).profiles[profileDirectory]
    }

    /// The profile a browser started without `--profile-directory` will have
    /// opened. Chromium reopens whatever it used last, so assuming `Default`
    /// names the wrong profile on any machine with more than one.
    public func lastUsedProfileDirectory(inUserDataDirectory directory: String?) -> String? {
        guard let directory else { return nil }
        return localState(inUserDataDirectory: directory).lastUsed
    }

    private func localState(inUserDataDirectory directory: String) -> LocalState {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[directory], now().timeIntervalSince(cached.readAt) < cacheLifetime {
            return cached.state
        }
        let parsed = Self.parse(fileContents(directory + "/Local State"))
        // Only a successful read is remembered. The browser rewrites this file
        // while it runs, so a read can land mid-write and come back empty;
        // caching that would leave the menu bar app showing no profile name
        // until the entry expired, when the next poll would have got it.
        if !parsed.isEmpty { cache[directory] = (parsed, now()) }
        return parsed
    }

    static func parse(_ data: Data?) -> LocalState {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any]
        else { return LocalState(profiles: [:], lastUsed: nil) }

        let profiles = (profile["info_cache"] as? [String: Any] ?? [:]).reduce(into: [String: ChromeProfile]()) { result, entry in
            guard let attributes = entry.value as? [String: Any] else { return }
            let name = attributes["name"] as? String ?? entry.key
            let account = (attributes["user_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            result[entry.key] = ChromeProfile(name: name, accountName: account)
        }
        return LocalState(
            profiles: profiles,
            lastUsed: (profile["last_used"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

import Foundation

public enum ChromeFormatting {
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let absolute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    public static func absoluteTime(_ date: Date) -> String { absolute.string(from: date) }

    public static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        relative.localizedString(for: date, relativeTo: now)
    }

    public static func memory(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        if megabytes >= 1024 { return String(format: "%.1f GB", megabytes / 1024) }
        return String(format: "%.0f MB", megabytes)
    }
}

extension ChromeInstance {
    /// The markers that change how you treat an instance: whether it has a UI,
    /// whether something can drive it, and whether a tool started it. Collapsed
    /// into short tags because the menu has one line per instance.
    public var tags: [String] {
        var tags: [String] = []
        if isHeadless { tags.append("headless") }
        switch remoteDebugging {
        case .port:
            // With no port resolved there is nothing to check the browser
            // against, so it is left at that rather than also called silent.
            guard let port = remoteDebuggingPort else {
                tags.append("port unresolved")
                break
            }
            if sharesDebugPort {
                tags.append("port \(port), contested")
            } else if !isListeningOnDebugPort {
                tags.append("port \(port), not listening")
            } else {
                tags.append("port \(port)")
            }
        case .pipe: tags.append("debug pipe")
        case nil: break
        }
        if !automationFlags.isEmpty { tags.append("automated") }
        if isOrphaned { tags.append("orphaned") }
        return tags
    }

    /// One line for the menu bar, where there is no room for a table.
    public var menuSummary: String {
        var parts = [displayName]
        if isOrphaned {
            parts.append("\(helpers.count) stray helper\(helpers.count == 1 ? "" : "s")")
        } else {
            parts.append(profileDescription)
            parts.append("\(helpers.count) helper\(helpers.count == 1 ? "" : "s")")
        }
        parts.append(String(format: "%.1f%% CPU", totalCPUPercent))
        parts.append(ChromeFormatting.memory(totalResidentMemoryBytes))
        let tags = tags
        if !tags.isEmpty { parts.append("[\(tags.joined(separator: ", "))]") }
        return parts.joined(separator: " — ")
    }
}

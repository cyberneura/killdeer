import Foundation

public enum ChromeRemoteDebugging: Equatable, Sendable {
    case port(Int)
    case pipe
}

public enum ChromeProcessRole: Equatable, Sendable {
    case browser
    case renderer
    case gpu
    case zygote
    case utility(subType: String?)
    case other(String)

    public var displayName: String {
        switch self {
        case .browser: return "browser"
        case .renderer: return "renderer"
        case .gpu: return "gpu-process"
        case .zygote: return "zygote"
        case let .utility(subType):
            guard let subType, !subType.isEmpty else { return "utility" }
            return "utility (\(Self.shortUtilityName(subType)))"
        case let .other(value): return value
        }
    }

    /// Utility sub-types arrive as mojo interface names such as
    /// `network.mojom.NetworkService`, which is mostly namespace. The tail is
    /// the part that says what the process is doing.
    private static func shortUtilityName(_ subType: String) -> String {
        subType.split(separator: ".").last.map(String.init) ?? subType
    }
}

/// The Chrome switches Killdeer cares about, pulled out of a process's argv.
///
/// Only the `--flag=value` form is read for value-bearing switches. Chrome does
/// not accept `--user-data-dir /tmp/x`; it treats the second word as a URL to
/// open, so reading it as the flag's value would report a directory the browser
/// never used.
public struct ChromeCommandLine: Equatable, Sendable {
    public let executablePath: String
    public let processType: String?
    public let utilitySubType: String?
    public let userDataDirectory: String?
    public let profileDirectory: String?
    /// `--database=<user-data-dir>/Crashpad`, present only on the crash
    /// handler. It is the one switch that says which browser that process
    /// belongs to, and the handler is double-forked onto launchd so its parent
    /// link cannot say.
    public let crashpadDatabase: String?
    public let isHeadless: Bool
    public let remoteDebugging: ChromeRemoteDebugging?
    public let automationFlags: [String]

    /// Switches that mean "something is driving this browser rather than a
    /// person". Presented together because any one of them answers the question
    /// the command exists for.
    private static let automationSwitches = [
        "--enable-automation",
        "--test-type",
        "--no-sandbox",
        "--disable-blink-features=AutomationControlled",
        "--load-extension",
        "--disable-extensions-except",
        "--remote-allow-origins"
    ]

    /// - Parameter executablePath: the file the kernel recorded as executed.
    ///   Deliberately not `arguments[0]`, which is only what the parent chose
    ///   to pass and can be a bare name or an outright lie.
    public init(executablePath: String, arguments: [String]) {
        self.executablePath = executablePath

        let switches = arguments.dropFirst()
        func value(of name: String) -> String? {
            let prefix = "--\(name)="
            guard let match = switches.last(where: { $0.hasPrefix(prefix) }) else { return nil }
            let value = String(match.dropFirst(prefix.count))
            return value.isEmpty ? nil : value
        }

        processType = value(of: "type")
        utilitySubType = value(of: "utility-sub-type")
        userDataDirectory = value(of: "user-data-dir")
        profileDirectory = value(of: "profile-directory")
        crashpadDatabase = value(of: "database")

        // `chrome-headless-shell` is a separate binary with no --headless switch:
        // being headless is the only thing it does.
        isHeadless = switches.contains { $0 == "--headless" || $0.hasPrefix("--headless=") }
            || URL(fileURLWithPath: executablePath).lastPathComponent == "chrome-headless-shell"

        if switches.contains("--remote-debugging-pipe") {
            remoteDebugging = .pipe
        } else if let port = value(of: "remote-debugging-port").flatMap(Int.init) {
            remoteDebugging = .port(port)
        } else {
            remoteDebugging = nil
        }

        automationFlags = Self.automationSwitches.filter { name in
            switches.contains { $0 == name || $0.hasPrefix(name + "=") }
        }
    }

    /// Whether this executable is the browser itself rather than something it
    /// ships alongside.
    ///
    /// `--type=` is not enough on its own: `chrome_crashpad_handler` has its own
    /// switches and none of them is `--type=`, so that test alone makes it look
    /// like a second copy of the browser. Everything a browser bundles
    /// lives under `Frameworks/`, and only the browser sits directly in the
    /// bundle's `MacOS` directory.
    public var isBrowserMainExecutable: Bool {
        guard !executablePath.contains("/Frameworks/") else { return false }
        return executablePath.contains(".app/Contents/MacOS/")
            || URL(fileURLWithPath: executablePath).lastPathComponent == "chrome-headless-shell"
    }

    public var role: ChromeProcessRole {
        switch processType {
        case nil:
            guard isBrowserMainExecutable else {
                return .other(URL(fileURLWithPath: executablePath).lastPathComponent)
            }
            return .browser
        case "renderer": return .renderer
        case "gpu-process": return .gpu
        case "zygote": return .zygote
        case "utility": return .utility(subType: utilitySubType)
        case let other?: return .other(other)
        }
    }
}

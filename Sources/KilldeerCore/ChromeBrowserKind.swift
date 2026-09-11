import Foundation

/// A Chromium-derived browser Killdeer knows how to describe.
///
/// Identification is by the `.app` bundle in the executable path rather than by
/// process name. Electron apps ship the same Chromium helpers and the same
/// `chrome_crashpad_handler`, so a name match would file a code editor's
/// helpers under Chrome. A bundle name is specific to the browser that owns the
/// process.
///
/// This says which browser a process belongs to, not which running instance of
/// it; `ChromeInspector` decides that from the parent chain.
public enum ChromeBrowserKind: String, CaseIterable, Sendable {
    case chrome
    case chromeBeta
    case chromeCanary
    case chromeForTesting
    case chromium
    case brave
    case braveBeta
    case braveNightly
    case edge
    case edgeBeta
    case edgeDev
    case edgeCanary
    case vivaldi
    case comet
    case arc

    public var displayName: String {
        switch self {
        case .chrome: return "Google Chrome"
        case .chromeBeta: return "Google Chrome Beta"
        case .chromeCanary: return "Google Chrome Canary"
        case .chromeForTesting: return "Google Chrome for Testing"
        case .chromium: return "Chromium"
        case .brave: return "Brave Browser"
        case .braveBeta: return "Brave Browser Beta"
        case .braveNightly: return "Brave Browser Nightly"
        case .edge: return "Microsoft Edge"
        case .edgeBeta: return "Microsoft Edge Beta"
        case .edgeDev: return "Microsoft Edge Dev"
        case .edgeCanary: return "Microsoft Edge Canary"
        case .vivaldi: return "Vivaldi"
        case .comet: return "Comet"
        case .arc: return "Arc"
        }
    }

    /// Where the browser keeps its profiles when no `--user-data-dir` is given.
    ///
    /// This is the common case rather than the fallback: a browser launched
    /// from the Dock or Finder carries no switches at all, so without this
    /// table almost every instance would report an unknown profile.
    public var defaultUserDataDirectory: String {
        let root = NSHomeDirectory() + "/Library/Application Support/"
        switch self {
        case .chrome: return root + "Google/Chrome"
        case .chromeBeta: return root + "Google/Chrome Beta"
        case .chromeCanary: return root + "Google/Chrome Canary"
        case .chromeForTesting: return root + "Google/Chrome for Testing"
        case .chromium: return root + "Chromium"
        case .brave: return root + "BraveSoftware/Brave-Browser"
        case .braveBeta: return root + "BraveSoftware/Brave-Browser-Beta"
        case .braveNightly: return root + "BraveSoftware/Brave-Browser-Nightly"
        case .edge: return root + "Microsoft Edge"
        case .edgeBeta: return root + "Microsoft Edge Beta"
        case .edgeDev: return root + "Microsoft Edge Dev"
        case .edgeCanary: return root + "Microsoft Edge Canary"
        case .vivaldi: return root + "Vivaldi"
        case .comet: return root + "Perplexity/Comet"
        case .arc: return root + "Arc/User Data"
        }
    }

    /// Every release channel gets its own case because every channel gets its
    /// own profile directory. Folding Edge Beta into Edge would have it read
    /// stable Edge's `Local State` and report a profile that browser never
    /// opened, which is the failure the directory table exists to prevent.
    private static let bundleNames: [(String, ChromeBrowserKind)] = [
        ("Google Chrome for Testing.app", .chromeForTesting),
        ("Google Chrome Canary.app", .chromeCanary),
        ("Google Chrome Beta.app", .chromeBeta),
        ("Google Chrome.app", .chrome),
        ("Brave Browser Nightly.app", .braveNightly),
        ("Brave Browser Beta.app", .braveBeta),
        ("Brave Browser.app", .brave),
        ("Microsoft Edge Canary.app", .edgeCanary),
        ("Microsoft Edge Beta.app", .edgeBeta),
        ("Microsoft Edge Dev.app", .edgeDev),
        ("Microsoft Edge.app", .edge),
        ("Chromium.app", .chromium),
        ("Vivaldi.app", .vivaldi),
        ("Comet.app", .comet),
        ("Arc.app", .arc)
    ]

    /// The default directory only applies to a browser installed as an app
    /// bundle. `chrome-headless-shell` is always launched by a tool that passes
    /// its own `--user-data-dir`, so naming Chrome for Testing's directory here
    /// would report a profile that process never opened.
    public static func defaultUserDataDirectory(forExecutablePath path: String) -> String? {
        guard let kind = detect(executablePath: path), path.contains(".app/") else { return nil }
        return kind.defaultUserDataDirectory
    }

    public static func detect(executablePath: String) -> ChromeBrowserKind? {
        if let match = bundleNames.first(where: { executablePath.contains($0.0) }) { return match.1 }
        // Puppeteer and Playwright download a bare `chrome-headless-shell` that
        // lives in a cache directory with no bundle around it.
        if URL(fileURLWithPath: executablePath).lastPathComponent == "chrome-headless-shell" {
            return .chromeForTesting
        }
        return nil
    }
}

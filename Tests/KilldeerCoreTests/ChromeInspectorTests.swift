import XCTest
@testable import KilldeerCore

final class ChromeCommandLineTests: XCTestCase {
    func testExtractsUserDataDirProfileHeadlessAndPort() {
        let line = ChromeCommandLine(executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", arguments: ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "--user-data-dir=/tmp/agent-profile",
            "--profile-directory=Profile 3",
            "--headless=new",
            "--remote-debugging-port=9222"
        ])
        XCTAssertEqual(line.userDataDirectory, "/tmp/agent-profile")
        XCTAssertEqual(line.profileDirectory, "Profile 3")
        XCTAssertTrue(line.isHeadless)
        XCTAssertEqual(line.remoteDebugging, .port(9222))
        XCTAssertEqual(line.role, .browser)
    }

    func testAbsentSwitchesReadAsUnset() {
        let line = ChromeCommandLine(executablePath: "/Applications/Vivaldi.app/Contents/MacOS/Vivaldi", arguments: ["/Applications/Vivaldi.app/Contents/MacOS/Vivaldi"])
        XCTAssertNil(line.userDataDirectory)
        XCTAssertNil(line.profileDirectory)
        XCTAssertNil(line.remoteDebugging)
        XCTAssertFalse(line.isHeadless)
        XCTAssertTrue(line.automationFlags.isEmpty)
    }

    func testBareHeadlessSwitchCounts() {
        XCTAssertTrue(ChromeCommandLine(executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", arguments: ["chrome", "--headless"]).isHeadless)
        XCTAssertTrue(ChromeCommandLine(executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", arguments: ["chrome", "--headless=old"]).isHeadless)
    }

    func testHeadlessShellIsHeadlessWithoutTheSwitch() {
        let line = ChromeCommandLine(executablePath: "/Users/me/.cache/puppeteer/chrome-headless-shell", arguments: ["/Users/me/.cache/puppeteer/chrome-headless-shell"])
        XCTAssertTrue(line.isHeadless)
    }

    /// Chrome reads a bare `/tmp/x` after `--user-data-dir` as a URL to open,
    /// so treating it as the flag's value would name a directory the browser
    /// never used.
    func testSpaceSeparatedValueIsNotReadAsTheSwitchValue() {
        let line = ChromeCommandLine(executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", arguments: ["chrome", "--user-data-dir", "/tmp/not-a-value"])
        XCTAssertNil(line.userDataDirectory)
    }

    /// The shell expands `~` before the browser is ever executed. A literal `~`
    /// that survives into argv is one Chromium does not expand either: it makes
    /// a directory named `~` under its working directory. Expanding it here
    /// would report a path the browser is not using.
    func testLiteralTildeIsLeftAlone() {
        let line = ChromeCommandLine(executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", arguments: ["chrome", "--user-data-dir=~/chrome-profile"])
        XCTAssertEqual(line.userDataDirectory, "~/chrome-profile")
    }

    func testDebuggingPipeIsDistinctFromAPort() {
        let line = ChromeCommandLine(executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", arguments: ["chrome", "--remote-debugging-pipe"])
        XCTAssertEqual(line.remoteDebugging, .pipe)
    }

    func testZeroPortIsKeptRatherThanDiscarded() {
        XCTAssertEqual(ChromeCommandLine(executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", arguments: ["chrome", "--remote-debugging-port=0"]).remoteDebugging, .port(0))
    }

    func testAutomationSwitchesAreCollected() {
        let line = ChromeCommandLine(executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", arguments: ["chrome", "--enable-automation", "--load-extension=/tmp/ext", "--lang=en-US"
        ])
        XCTAssertEqual(line.automationFlags, ["--enable-automation", "--load-extension"])
    }

    func testRolesComeFromTheTypeSwitch() {
        XCTAssertEqual(ChromeCommandLine(executablePath: "x", arguments: ["x", "--type=renderer"]).role, .renderer)
        XCTAssertEqual(ChromeCommandLine(executablePath: "x", arguments: ["x", "--type=gpu-process"]).role, .gpu)
        XCTAssertEqual(
            ChromeCommandLine(executablePath: "x", arguments: ["x", "--type=utility", "--utility-sub-type=network.mojom.NetworkService"]).role.displayName,
            "utility (NetworkService)"
        )
    }

    /// `chrome_crashpad_handler` carries no switches and is reparented to
    /// launchd, so argv alone makes it look like a second copy of the browser.
    func testCrashpadHandlerIsNotTakenForTheBrowser() {
        let line = ChromeCommandLine(executablePath: "/Applications/Vivaldi.app/Contents/Frameworks/Vivaldi Framework.framework/Versions/8.2/Helpers/chrome_crashpad_handler", arguments: ["/Applications/Vivaldi.app/Contents/Frameworks/Vivaldi Framework.framework/Versions/8.2/Helpers/chrome_crashpad_handler"
        ])
        XCTAssertFalse(line.isBrowserMainExecutable)
        XCTAssertEqual(line.role, .other("chrome_crashpad_handler"))
    }
}

final class ChromeBrowserKindTests: XCTestCase {
    func testEditionsAreDistinguishedFromStableChrome() {
        XCTAssertEqual(ChromeBrowserKind.detect(executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"), .chrome)
        XCTAssertEqual(ChromeBrowserKind.detect(executablePath: "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary"), .chromeCanary)
        XCTAssertEqual(ChromeBrowserKind.detect(executablePath: "/tmp/Google Chrome for Testing.app/Contents/MacOS/x"), .chromeForTesting)
    }

    /// Electron apps ship the same Chromium helpers; matching on process name
    /// would file a code editor's helpers under orphaned Chrome.
    func testElectronAppsAreNotChromeBrowsers() {
        XCTAssertNil(ChromeBrowserKind.detect(executablePath: "/Applications/Orca.app/Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler"))
        XCTAssertNil(ChromeBrowserKind.detect(executablePath: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"))
    }

    /// Each release channel keeps its own profiles. Folding Edge Beta into
    /// Edge would read stable Edge's Local State and name a profile that
    /// browser never opened.
    func testReleaseChannelsKeepSeparateProfileDirectories() {
        let support = NSHomeDirectory() + "/Library/Application Support/"
        let cases: [(String, ChromeBrowserKind, String)] = [
            ("/Applications/Microsoft Edge Beta.app/Contents/MacOS/x", .edgeBeta, support + "Microsoft Edge Beta"),
            ("/Applications/Microsoft Edge Canary.app/Contents/MacOS/x", .edgeCanary, support + "Microsoft Edge Canary"),
            ("/Applications/Brave Browser Nightly.app/Contents/MacOS/x", .braveNightly, support + "BraveSoftware/Brave-Browser-Nightly"),
            ("/Applications/Brave Browser.app/Contents/MacOS/x", .brave, support + "BraveSoftware/Brave-Browser")
        ]
        for (path, kind, directory) in cases {
            XCTAssertEqual(ChromeBrowserKind.detect(executablePath: path), kind, path)
            XCTAssertEqual(ChromeBrowserKind.defaultUserDataDirectory(forExecutablePath: path), directory, path)
        }
    }

    func testDefaultDirectoryOnlyAppliesToBundledBrowsers() {
        XCTAssertEqual(
            ChromeBrowserKind.defaultUserDataDirectory(forExecutablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
            NSHomeDirectory() + "/Library/Application Support/Google/Chrome"
        )
        XCTAssertNil(ChromeBrowserKind.defaultUserDataDirectory(forExecutablePath: "/Users/me/.cache/puppeteer/chrome-headless-shell"))
    }
}

final class ChromeProfileCatalogTests: XCTestCase {
    func testReadsNameAndAccountFromLocalState() {
        let catalog = ChromeProfileCatalog { _ in Data("""
        {"profile":{"info_cache":{"Profile 3":{"name":"Work","user_name":"me@example.com"}}}}
        """.utf8) }
        let profile = catalog.profile(userDataDirectory: "/tmp/x", profileDirectory: "Profile 3")
        XCTAssertEqual(profile, ChromeProfile(name: "Work", accountName: "me@example.com"))
    }

    /// Chrome writes an empty string rather than dropping the key for a local
    /// profile, so an empty value has to read as "not signed in".
    func testEmptyAccountReadsAsSignedOut() {
        let catalog = ChromeProfileCatalog { _ in Data("""
        {"profile":{"info_cache":{"Default":{"name":"Personal","user_name":""}}}}
        """.utf8) }
        XCTAssertNil(catalog.profile(userDataDirectory: "/tmp/x", profileDirectory: "Default")?.accountName)
    }

    /// A read landing mid-rewrite must not leave the menu bar app without a
    /// profile name for the rest of its run.
    func testATransientReadFailureIsNotCachedForever() {
        var attempt = 0
        let catalog = ChromeProfileCatalog { _ in
            attempt += 1
            guard attempt > 1 else { return Data("{\"profile\":{\"info_c".utf8) }
            return Data("""
            {"profile":{"info_cache":{"Default":{"name":"Personal","user_name":""}}}}
            """.utf8)
        }
        XCTAssertNil(catalog.profile(userDataDirectory: "/tmp/x", profileDirectory: "Default"))
        XCTAssertEqual(catalog.profile(userDataDirectory: "/tmp/x", profileDirectory: "Default")?.name, "Personal")
    }

    /// Caching for the life of the process would mean a profile rename never
    /// reaches the menu bar app, which runs for days.
    func testACachedProfileIsRereadOnceTheEntryExpires() {
        var clock = Date(timeIntervalSince1970: 0)
        var name = "Before"
        let catalog = ChromeProfileCatalog(cacheLifetime: 30, now: { clock }) { _ in
            Data("{\"profile\":{\"info_cache\":{\"Default\":{\"name\":\"\(name)\"}}}}".utf8)
        }
        XCTAssertEqual(catalog.profile(userDataDirectory: "/tmp/x", profileDirectory: "Default")?.name, "Before")

        name = "After"
        clock = clock.addingTimeInterval(10)
        XCTAssertEqual(catalog.profile(userDataDirectory: "/tmp/x", profileDirectory: "Default")?.name, "Before")

        clock = clock.addingTimeInterval(30)
        XCTAssertEqual(catalog.profile(userDataDirectory: "/tmp/x", profileDirectory: "Default")?.name, "After")
    }

    func testUnreadableOrTruncatedLocalStateIsTolerated() {
        XCTAssertTrue(ChromeProfileCatalog.parse(nil).isEmpty)
        XCTAssertTrue(ChromeProfileCatalog.parse(Data("{\"profile\":{\"info_c".utf8)).isEmpty)
        XCTAssertNil(ChromeProfileCatalog.parse(nil).lastUsed)
    }
}

final class ChromeInspectorTests: XCTestCase {
    func testHelpersAreFoldedIntoTheirBrowserAndInheritItsProfile() {
        let browser = finding(pid: 100, parent: 1, name: "Google Chrome", args: [
            chromePath, "--user-data-dir=/tmp/agent", "--profile-directory=Profile 3", "--remote-debugging-port=9222"
        ])
        let renderer = finding(pid: 101, parent: 100, name: "Google Chrome Helper (Renderer)", args: [helperPath, "--type=renderer"])
        let gpu = finding(pid: 102, parent: 100, name: "Google Chrome Helper (GPU)", args: [helperPath, "--type=gpu-process"])

        let instances = ChromeInspector(catalog: catalog()).instances(from: [browser, renderer, gpu])

        XCTAssertEqual(instances.count, 1)
        let instance = try! XCTUnwrap(instances.first)
        XCTAssertEqual(instance.helpers.count, 2)
        XCTAssertEqual(instance.userDataDirectory, "/tmp/agent")
        XCTAssertEqual(instance.profile?.name, "Work")
        XCTAssertEqual(instance.remoteDebuggingPort, 9222)
        XCTAssertFalse(instance.isOrphaned)
    }

    func testBrowserWithoutSwitchesFallsBackToTheDefaultProfile() {
        let browser = finding(pid: 200, parent: 1, name: "Google Chrome", args: [chromePath])
        let instance = ChromeInspector(catalog: catalog()).instances(from: [browser]).first
        XCTAssertEqual(instance?.userDataDirectory, NSHomeDirectory() + "/Library/Application Support/Google/Chrome")
        XCTAssertEqual(instance?.profileDirectory, "Default")
    }

    /// Crashpad double-forks its handler onto launchd, so its parent link can
    /// never reach the browser. Without the `--database` match every healthy
    /// browser grows a phantom "orphaned" row beside it.
    func testCrashpadHandlerIsAttributedToItsBrowserDespiteALaunchdParent() {
        let browser = finding(pid: 100, parent: 1, name: "Google Chrome", args: [chromePath, "--user-data-dir=/tmp/agent"])
        let crashpad = finding(pid: 101, parent: 1, name: "chrome_crashpad_handler", args: [
            crashpadPath, "--monitor-self-annotation=ptype=crashpad-handler", "--database=/tmp/agent/Crashpad"
        ])
        let instances = ChromeInspector(catalog: catalog()).instances(from: [browser, crashpad])
        XCTAssertEqual(instances.count, 1)
        XCTAssertFalse(instances[0].isOrphaned)
        XCTAssertEqual(instances[0].helpers.map(\.identity.pid), [101])
    }

    /// A Chrome given its own `--user-data-dir` still writes crashes under the
    /// default directory, so `--database` matches nothing. That is exactly the
    /// throwaway-profile case this command exists for, so the installation the
    /// handler came from has to settle it.
    func testCrashpadHandlerIsPlacedByItsInstallationWhenTheDatabaseDoesNotMatch() {
        let browser = finding(pid: 100, parent: 1, name: "Google Chrome", args: [chromePath, "--user-data-dir=/tmp/agent"])
        let crashpad = finding(pid: 101, parent: 1, name: "chrome_crashpad_handler", args: [
            crashpadPath, "--database=/Users/me/Library/Application Support/Google/Chrome/Crashpad"
        ])
        let instances = ChromeInspector(catalog: catalog()).instances(from: [browser, crashpad])
        XCTAssertEqual(instances.count, 1)
        XCTAssertEqual(instances[0].helpers.map(\.identity.pid), [101])
    }

    /// One handler serves the whole installation, so naming one of several
    /// running browsers as its owner would be a guess.
    func testCrashpadHandlerIsReportedUnderNoInstanceWhenSeveralShareTheInstallation() {
        let first = finding(pid: 100, parent: 1, name: "Google Chrome", args: [chromePath, "--user-data-dir=/tmp/a"])
        let second = finding(pid: 200, parent: 1, name: "Google Chrome", args: [chromePath, "--user-data-dir=/tmp/b"])
        let crashpad = finding(pid: 101, parent: 1, name: "chrome_crashpad_handler", args: [
            crashpadPath, "--database=/tmp/elsewhere/Crashpad"
        ])
        let instances = ChromeInspector(catalog: catalog()).instances(from: [first, second, crashpad])
        XCTAssertEqual(instances.count, 2)
        XCTAssertTrue(instances.allSatisfy { $0.helpers.isEmpty })
        XCTAssertFalse(instances.contains { $0.isOrphaned })
    }

    /// The database still wins when it does match, even with several browsers
    /// running out of the same installation.
    func testCrashpadDatabaseWinsOverTheInstallationGuess() {
        let first = finding(pid: 100, parent: 1, name: "Google Chrome", args: [chromePath, "--user-data-dir=/tmp/a"])
        let second = finding(pid: 200, parent: 1, name: "Google Chrome", args: [chromePath, "--user-data-dir=/tmp/b"])
        let crashpad = finding(pid: 101, parent: 1, name: "chrome_crashpad_handler", args: [
            crashpadPath, "--database=/tmp/b/Crashpad"
        ])
        let instances = ChromeInspector(catalog: catalog()).instances(from: [first, second, crashpad])
        XCTAssertEqual(instances.first { $0.browser?.identity.pid == 200 }?.helpers.map(\.identity.pid), [101])
        XCTAssertEqual(instances.first { $0.browser?.identity.pid == 100 }?.helpers.count, 0)
    }

    func testCrashpadHandlerOfAVanishedBrowserStaysOrphaned() {
        let crashpad = finding(pid: 101, parent: 1, name: "chrome_crashpad_handler", args: [
            crashpadPath, "--database=/tmp/gone/Crashpad"
        ])
        let instances = ChromeInspector(catalog: catalog()).instances(from: [crashpad])
        XCTAssertEqual(instances.count, 1)
        XCTAssertTrue(instances[0].isOrphaned)
    }

    /// Chromium reopens the profile it used last, so assuming "Default" names
    /// the wrong profile on any machine with more than one.
    func testBrowserWithoutAProfileSwitchUsesLastUsed() {
        let browser = finding(pid: 100, parent: 1, name: "Google Chrome", args: [chromePath, "--user-data-dir=/tmp/agent"])
        let catalog = ChromeProfileCatalog { _ in Data("""
        {"profile":{"last_used":"Profile 3","info_cache":{
          "Default":{"name":"Personal","user_name":""},
          "Profile 3":{"name":"Work","user_name":"me@example.com"}}}}
        """.utf8) }
        let instance = ChromeInspector(catalog: catalog).instances(from: [browser]).first
        XCTAssertEqual(instance?.profileDirectory, "Profile 3")
        XCTAssertEqual(instance?.profileDescription, "Work <me@example.com>")
    }

    /// Vivaldi never writes the key, and its single profile is Default.
    func testBrowserWithoutLastUsedFallsBackToDefault() {
        let browser = finding(pid: 100, parent: 1, name: "Vivaldi", args: ["/Applications/Vivaldi.app/Contents/MacOS/Vivaldi"])
        let catalog = ChromeProfileCatalog { _ in Data("""
        {"profile":{"info_cache":{"Default":{"name":"Work","user_name":""}}}}
        """.utf8) }
        XCTAssertEqual(ChromeInspector(catalog: catalog).instances(from: [browser]).first?.profileDirectory, "Default")
    }

    func testHelperWithNoSurvivingBrowserIsReportedAsOrphaned() {
        let orphan = finding(pid: 300, parent: 999, name: "Google Chrome Helper (Renderer)", args: [helperPath, "--type=renderer"])
        let instances = ChromeInspector(catalog: catalog()).instances(from: [orphan])
        XCTAssertEqual(instances.count, 1)
        XCTAssertTrue(instances[0].isOrphaned)
        XCTAssertNil(instances[0].userDataDirectory)
        XCTAssertEqual(instances[0].profileDescription, "profile unknown")
    }

    func testTwoBrowsersOnTheSameProfileStayApart() {
        let first = finding(pid: 400, parent: 1, name: "Google Chrome", args: [chromePath, "--user-data-dir=/tmp/agent"])
        let second = finding(pid: 500, parent: 1, name: "Google Chrome", args: [chromePath, "--user-data-dir=/tmp/agent"])
        let helper = finding(pid: 501, parent: 500, name: "helper", args: [helperPath, "--type=renderer"])
        let instances = ChromeInspector(catalog: catalog()).instances(from: [first, second, helper])
        XCTAssertEqual(instances.count, 2)
        XCTAssertEqual(instances.first(where: { $0.browser?.identity.pid == 500 })?.helpers.count, 1)
        XCTAssertEqual(instances.first(where: { $0.browser?.identity.pid == 400 })?.helpers.count, 0)
    }

    /// The switch says 0, meaning "choose a free port"; the real port is only
    /// in DevToolsActivePort, and that is the case most worth reporting.
    func testAutoAssignedPortIsResolvedFromDevToolsActivePort() {
        let browser = finding(pid: 600, parent: 1, name: "Google Chrome", args: [
            chromePath, "--user-data-dir=/tmp/agent", "--remote-debugging-port=0"
        ])
        let inspector = ChromeInspector(catalog: catalog()) { path in
            path == "/tmp/agent/DevToolsActivePort" ? "50618\n/devtools/browser/abc" : nil
        }
        let instance = inspector.instances(from: [browser]).first
        XCTAssertEqual(instance?.remoteDebugging, .port(0))
        XCTAssertEqual(instance?.remoteDebuggingPort, 50618)
        XCTAssertTrue(instance?.tags.contains("port 50618") == true)
    }

    func testMissingDevToolsActivePortLeavesThePortUnresolved() {
        let browser = finding(pid: 700, parent: 1, name: "Google Chrome", args: [
            chromePath, "--user-data-dir=/tmp/agent", "--remote-debugging-port=0"
        ])
        let instance = ChromeInspector(catalog: catalog()) { _ in nil }.instances(from: [browser]).first
        XCTAssertNil(instance?.remoteDebuggingPort)
        XCTAssertTrue(instance?.tags.contains("port unresolved") == true)
    }

    func testElectronHelpersAreNotListedAsChrome() {
        let electron = finding(pid: 800, parent: 1, name: "chrome_crashpad_handler", args: [
            "/Applications/Orca.app/Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler"
        ])
        XCTAssertTrue(ChromeInspector(catalog: catalog()).instances(from: [electron]).isEmpty)
    }

    /// argv is unreadable for another user's processes, and every reported
    /// field comes from argv, so such a browser is left out rather than listed
    /// as a row of unknowns.
    func testProcessWithUnreadableArgumentsIsSkipped() {
        let foreign = finding(pid: 850, parent: 1, name: "Google Chrome", args: [])
        XCTAssertTrue(ChromeInspector(catalog: catalog()).instances(from: [foreign]).isEmpty)
    }

    func testLauncherIsReportedWhenABrowserWasStartedByATool() {
        let node = finding(pid: 900, parent: 1, name: "node", args: ["/usr/local/bin/node"])
        let browser = finding(pid: 901, parent: 900, name: "Google Chrome", args: [chromePath])
        let instance = ChromeInspector(catalog: catalog()).instances(from: [node, browser]).first
        XCTAssertEqual(instance?.launchedBy, "node")
    }

    func testJSONReportKeepsOneShapeAcrossInstances() throws {
        let browser = finding(pid: 1000, parent: 1, name: "Google Chrome", args: [chromePath, "--remote-debugging-port=9222"])
        let orphan = finding(pid: 1001, parent: 999, name: "helper", args: [helperPath, "--type=renderer"])
        let instances = ChromeInspector(catalog: catalog()).instances(from: [browser, orphan])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(ChromeReport(instances: instances))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try XCTUnwrap(decoded["instances"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows[0].keys), Set(rows[1].keys))
        XCTAssertTrue(rows.contains { $0["remoteDebuggingPort"] is NSNull })
    }

    private let chromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    private let helperPath = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
    private let crashpadPath = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/chrome_crashpad_handler"

    private func catalog() -> ChromeProfileCatalog {
        ChromeProfileCatalog { _ in Data("""
        {"profile":{"info_cache":{"Profile 3":{"name":"Work","user_name":"me@example.com"}}}}
        """.utf8) }
    }

    private func finding(pid: pid_t, parent: pid_t, name: String, args: [String]) -> ProcessFinding {
        ProcessFinding(
            process: ProcessSnapshot(
                identity: ProcessIdentity(pid: pid, startTime: Date(timeIntervalSince1970: 1000)),
                parentPID: parent,
                name: name,
                executablePath: args.first ?? "",
                arguments: args,
                totalCPUTimeNanoseconds: 0,
                residentMemoryBytes: 1_048_576
            ),
            cpuPercent: 1,
            isOrphanChromeHelper: false,
            score: 0,
            reasons: []
        )
    }
}

import XCTest
@testable import KilldeerCore

final class AgentKindTests: XCTestCase {
    func testClaudeCodeIsKnownByTheExecutedLinkNotTheVersionedFile() {
        XCTAssertEqual(AgentKind.detect(executablePath: "/Users/me/.local/bin/claude", arguments: ["claude"]), .claudeCode)
        XCTAssertEqual(
            AgentKind.detect(executablePath: "/Users/me/.local/share/claude/versions/2.1.331", arguments: ["claude", "-p"]),
            .claudeCode
        )
    }

    func testCodexIsKnownByItsBinary() {
        XCTAssertEqual(AgentKind.detect(executablePath: "/opt/homebrew/Caskroom/codex/0.171.0/bin/codex", arguments: ["codex"]), .codex)
        XCTAssertEqual(
            AgentKind.detect(executablePath: "/opt/homebrew/lib/node_modules/@openai/codex/vendor/codex-aarch64-apple-darwin", arguments: ["codex"]),
            .codex
        )
    }

    func testTheDesktopAppsAreNotAgentSessions() {
        XCTAssertNil(AgentKind.detect(executablePath: "/Applications/Claude.app/Contents/MacOS/Claude", arguments: ["Claude"]))
        XCTAssertNil(AgentKind.detect(
            executablePath: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper",
            arguments: ["Claude Helper", "--type=renderer"]
        ))
        XCTAssertNil(AgentKind.detect(executablePath: "/Applications/Codex.app/Contents/MacOS/Codex", arguments: ["Codex"]))
    }

    func testAnNpmInstallIsKnownByTheScriptItsRuntimeRuns() {
        XCTAssertEqual(
            AgentKind.detect(
                executablePath: "/opt/homebrew/bin/node",
                arguments: ["node", "--no-warnings", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js", "-p"]
            ),
            .claudeCode
        )
        XCTAssertEqual(
            AgentKind.detect(
                executablePath: "/opt/homebrew/bin/node",
                arguments: ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"]
            ),
            .codex
        )
        XCTAssertEqual(AgentKind.detect(executablePath: "/opt/homebrew/bin/node", arguments: ["node", "/opt/homebrew/bin/claude"]), .claudeCode)
    }

    func testAnOrdinaryScriptOrAnArgumentNamingAnAgentIsNotOne() {
        XCTAssertNil(AgentKind.detect(executablePath: "/opt/homebrew/bin/node", arguments: ["node", "server.js", "claude"]))
        XCTAssertNil(AgentKind.detect(executablePath: "/bin/zsh", arguments: ["zsh", "-c", "claude -p hello"]))
        XCTAssertNil(AgentKind.detect(executablePath: "/usr/bin/grep", arguments: ["grep", "/Users/me/.local/bin/claude"]))
    }

    func testClaudeCodeRunningAsItsOwnSearchToolIsNotASession() {
        // Arrange: what the agent's shell runs for `grep` and `find`.
        let versioned = "/Users/me/.local/share/claude/versions/2.1.331"

        // Act / Assert
        XCTAssertNil(AgentKind.detect(executablePath: versioned, arguments: ["ugrep", "-G", "needle"]))
        XCTAssertNil(AgentKind.detect(executablePath: "/Users/me/.local/bin/claude", arguments: ["bfs", "-S", "dfs"]))
        XCTAssertEqual(AgentKind.embeddedTool(executablePath: versioned, arguments: ["rg", "needle"]), "rg")
    }

    func testClaudeCodeStartedByItsFullPathIsStillASession() {
        let versioned = "/Users/me/.local/share/claude/versions/2.1.331"
        XCTAssertEqual(AgentKind.detect(executablePath: versioned, arguments: [versioned, "-p"]), .claudeCode)
        XCTAssertEqual(
            AgentKind.detect(executablePath: "/Users/me/.local/bin/claude", arguments: ["/Users/me/.local/bin/claude"]),
            .claudeCode
        )
        XCTAssertNil(AgentKind.embeddedTool(executablePath: "/opt/homebrew/bin/codex", arguments: ["anything"]))
    }

    func testAProcessOfAnotherUserHasNoPathAndIsNotGuessedAt() {
        XCTAssertNil(AgentKind.detect(executablePath: "", arguments: []))
    }
}

final class AgentInspectorTests: XCTestCase {
    private let claude = "/Users/me/.local/bin/claude"
    private let codex = "/opt/homebrew/Caskroom/codex/0.171.0/bin/codex"

    private func finding(
        pid: pid_t, parent: pid_t, name: String, path: String = "/usr/bin/tool",
        args: [String] = [], cpu: Double = 0, memory: UInt64 = 0
    ) -> ProcessFinding {
        ProcessFinding(
            process: ProcessSnapshot(
                identity: ProcessIdentity(pid: pid, startTime: Date(timeIntervalSince1970: TimeInterval(pid))),
                parentPID: parent, name: name, executablePath: path,
                arguments: args.isEmpty ? [name] : args,
                totalCPUTimeNanoseconds: 0, residentMemoryBytes: memory
            ),
            cpuPercent: cpu, isOrphanChromeHelper: false, score: 0, reasons: []
        )
    }

    private func inspector(
        directories: [pid_t: String] = [:], kernel: [pid_t: KernelProcess] = [:]
    ) -> AgentInspector {
        AgentInspector(
            workingDirectory: { directories[$0] },
            kernelProcess: { kernel[$0] },
            homeDirectory: "/Users/me"
        )
    }

    func testAnAgentAndEverythingUnderItIsOneInstance() {
        // Arrange: a session with an MCP server and a shell running a build.
        let findings = [
            finding(pid: 100, parent: 50, name: "2.1.331", path: claude, args: ["claude"], cpu: 10, memory: 300),
            finding(pid: 101, parent: 100, name: "node", args: ["node", "/x/mcp-server.js"], cpu: 2, memory: 40),
            finding(pid: 102, parent: 100, name: "zsh", cpu: 0, memory: 5),
            finding(pid: 103, parent: 102, name: "swift-build", cpu: 80, memory: 500),
            finding(pid: 200, parent: 1, name: "Finder", cpu: 30, memory: 100),
        ]

        // Act
        let instances = inspector(directories: [100: "/Users/me/workspace/killdeer"]).instances(from: findings)

        // Assert
        XCTAssertEqual(instances.count, 1)
        let instance = instances[0]
        XCTAssertEqual(instance.kind, .claudeCode)
        XCTAssertEqual(instance.id, "pid:100")
        XCTAssertEqual(instance.allProcesses.map(\.identity.pid), [100, 103, 101, 102])
        XCTAssertEqual(instance.totalCPUPercent, 92, accuracy: 1e-9)
        XCTAssertEqual(instance.totalResidentMemoryBytes, 845)
        XCTAssertEqual(instance.workingDirectory, "/Users/me/workspace/killdeer")
        XCTAssertEqual(instance.directoryName, "killdeer")
    }

    func testAnAgentStartedByAnAgentBelongsToTheOuterSession() {
        // Arrange: Claude Code runs `codex exec` through a shell, and Codex
        // runs a tool of its own.
        let findings = [
            finding(pid: 100, parent: 50, name: "2.1.331", path: claude, args: ["claude"], cpu: 1),
            finding(pid: 110, parent: 100, name: "zsh"),
            finding(pid: 120, parent: 110, name: "codex", path: codex, args: ["codex", "exec", "review"], cpu: 5),
            finding(pid: 130, parent: 120, name: "rg", cpu: 40),
        ]

        // Act
        let instances = inspector().instances(from: findings)

        // Assert: one instance, with the inner agent listed as an agent.
        XCTAssertEqual(instances.map(\.id), ["pid:100"])
        XCTAssertEqual(instances[0].descendants.map(\.identity.pid), [130, 120, 110])
        XCTAssertEqual(instances[0].descendants.first { $0.identity.pid == 120 }?.kind, .codex)
        XCTAssertEqual(instances[0].descendants.first { $0.identity.pid == 120 }?.displayName, "Codex")
        XCTAssertEqual(instances[0].totalCPUPercent, 46, accuracy: 1e-9)
    }

    func testSeparateSessionsStaySeparateAndSortByKindThenDirectory() {
        // Arrange
        let findings = [
            finding(pid: 300, parent: 1, name: "codex", path: codex, args: ["codex", "app-server"]),
            finding(pid: 100, parent: 50, name: "2.1.331", path: claude, args: ["claude"]),
            finding(pid: 90, parent: 50, name: "2.1.331", path: claude, args: ["claude"]),
            finding(pid: 80, parent: 50, name: "2.1.331", path: claude, args: ["claude"]),
            finding(pid: 91, parent: 90, name: "caffeinate"),
        ]
        let directories: [pid_t: String] = [
            100: "/Users/me/workspace/alpha", 90: "/Users/me/workspace/Beta", 80: "/Users/me/workspace/alpha",
            300: "/Users/me",
        ]

        // Act
        let instances = inspector(directories: directories).instances(from: findings)

        // Assert: Claude Code first, by directory without regard to case,
        // then by PID where two sessions share a directory.
        XCTAssertEqual(instances.map(\.id), ["pid:80", "pid:100", "pid:90", "pid:300"])
        XCTAssertEqual(instances.map(\.directoryName), ["alpha", "alpha", "Beta", "~"])
        XCTAssertEqual(instances[2].descendants.map(\.identity.pid), [91])
    }

    func testAProcessWhoseChainDoesNotReachAnAgentIsLeftOut() {
        // Arrange: a server that double-forked onto launchd, as the desktop
        // app's helpers do.
        let findings = [
            finding(pid: 100, parent: 50, name: "2.1.331", path: claude, args: ["claude"]),
            finding(pid: 400, parent: 1, name: "node", args: ["node", "mcp.js"], cpu: 50),
        ]

        // Act
        let instances = inspector().instances(from: findings)

        // Assert
        XCTAssertEqual(instances.count, 1)
        XCTAssertTrue(instances[0].descendants.isEmpty)
    }

    func testASearchRunByTheAgentIsListedUnderItsToolName() {
        // Arrange
        let findings = [
            finding(pid: 100, parent: 50, name: "2.1.331", path: claude, args: ["claude"]),
            finding(pid: 110, parent: 100, name: "zsh"),
            finding(pid: 120, parent: 110, name: "2.1.331", path: claude, args: ["ugrep", "-r", "needle"], cpu: 98),
        ]

        // Act
        let instances = inspector().instances(from: findings)

        // Assert: one session, and the search is a process of it, not an agent.
        XCTAssertEqual(instances.map(\.id), ["pid:100"])
        let search = instances[0].descendants[0]
        XCTAssertEqual(search.identity.pid, 120)
        XCTAssertNil(search.kind)
        XCTAssertEqual(search.displayName, "ugrep")
    }

    func testATreeDeeperThanAnyFixedLimitStaysWhole() {
        // Arrange: a chain of 60 processes under the agent, with another
        // agent halfway down.
        var findings = [finding(pid: 1_000, parent: 50, name: "2.1.331", path: claude, args: ["claude"])]
        for depth in 1...60 {
            let pid = pid_t(1_000 + depth)
            findings.append(depth == 30
                ? finding(pid: pid, parent: pid - 1, name: "codex", path: codex, args: ["codex", "exec"], cpu: 1)
                : finding(pid: pid, parent: pid - 1, name: "sh", cpu: 1))
        }

        // Act
        let instances = inspector().instances(from: findings.shuffled())

        // Assert
        XCTAssertEqual(instances.map(\.id), ["pid:1000"])
        XCTAssertEqual(instances[0].descendants.count, 60)
        XCTAssertEqual(instances[0].totalCPUPercent, 60, accuracy: 1e-9)
    }

    func testAScriptRuntimeGivenProgramTextIsNotLabelledWithIt() {
        // Arrange: inline code can hold a token, and the label is shown.
        let findings = [
            finding(pid: 100, parent: 50, name: "2.1.331", path: claude, args: ["claude"]),
            finding(pid: 101, parent: 100, name: "node", args: ["node", "-e", "fetch(url, {headers: {auth: 'secret'}})"]),
            finding(pid: 102, parent: 100, name: "python3", args: ["python3", "-c", "token='secret'"]),
            finding(pid: 103, parent: 100, name: "node", args: ["node", "print('secret')  # no option before it"]),
            finding(pid: 104, parent: 100, name: "node", args: ["node", "/srv/app/server.js", "--port", "1"]),
        ]

        // Act
        let names = inspector().instances(from: findings)[0].descendants
            .sorted { $0.identity.pid < $1.identity.pid }
            .map(\.displayName)

        // Assert
        XCTAssertEqual(names, ["node", "python3", "node", "node server.js"])
    }

    func testCodexPointedAtAProjectIsListedUnderThatProject() {
        // Arrange: three sessions started from the same directory.
        let findings = [
            finding(pid: 300, parent: 50, name: "codex", path: codex, args: ["codex", "exec", "-C", "/Users/me/workspace/alpha", "fix"]),
            finding(pid: 301, parent: 50, name: "codex", path: codex, args: ["codex", "--cd=../beta", "exec", "fix"]),
            finding(pid: 302, parent: 50, name: "codex", path: codex, args: ["codex", "exec", "fix"]),
            finding(pid: 100, parent: 50, name: "2.1.331", path: claude, args: ["claude", "-C", "/elsewhere"]),
        ]
        let started = "/Users/me/workspace/launcher"
        let directories: [pid_t: String] = [300: started, 301: started, 302: started, 100: started]

        // Act
        let instances = inspector(directories: directories).instances(from: findings)
        let byPID = Dictionary(uniqueKeysWithValues: instances.map { ($0.root.identity.pid, $0.workingDirectory) })

        // Assert: only Codex has the option; for Claude Code it means nothing.
        XCTAssertEqual(byPID[300], "/Users/me/workspace/alpha")
        XCTAssertEqual(byPID[301], "/Users/me/workspace/beta")
        XCTAssertEqual(byPID[302], started)
        XCTAssertEqual(byPID[100], started)
    }

    func testNoAgentsGiveNoInstances() {
        let findings = [finding(pid: 10, parent: 1, name: "zsh"), finding(pid: 11, parent: 10, name: "vim")]
        XCTAssertTrue(inspector().instances(from: findings).isEmpty)
    }

    func testTheLauncherIsTheTerminalBehindTheShellAndTheRootOwnedLogin() {
        // Arrange: claude ← zsh ← login ← terminal. `login` runs as root, so
        // there is no snapshot of it and only the kernel can name its parent.
        let findings = [
            finding(pid: 100, parent: 90, name: "2.1.331", path: claude, args: ["claude"]),
            finding(pid: 90, parent: 80, name: "zsh"),
            finding(pid: 70, parent: 1, name: "iTerm2"),
        ]
        let kernel: [pid_t: KernelProcess] = [80: KernelProcess(parentPID: 70, name: "login")]

        // Act
        let withKernel = inspector(kernel: kernel).instances(from: findings)
        let withoutKernel = inspector().instances(from: findings)

        // Assert
        XCTAssertEqual(withKernel[0].launchedBy, "iTerm2")
        XCTAssertNil(withoutKernel[0].launchedBy)
    }

    func testTheLauncherIsTheAppRatherThanItsHelperProcesses() {
        // Arrange: an editor's extension host starts the agent through a pty
        // helper.
        let findings = [
            finding(pid: 100, parent: 90, name: "2.1.331", path: claude, args: ["claude"]),
            finding(pid: 90, parent: 80, name: "Python"),
            finding(pid: 80, parent: 70, name: "Code Helper (Plugin)"),
            finding(pid: 70, parent: 1, name: "Code"),
        ]

        // Act
        let instances = inspector().instances(from: findings)

        // Assert
        XCTAssertEqual(instances[0].launchedBy, "Code")
    }

    func testAnAgentStartedByLaunchdHasNoLauncher() {
        let findings = [finding(pid: 300, parent: 1, name: "codex", path: codex, args: ["codex", "app-server"])]
        XCTAssertNil(inspector().instances(from: findings)[0].launchedBy)
    }

    func testAParentChainThatLoopsEnds() {
        // Arrange: two processes naming each other as parent, which a
        // recycled PID can produce.
        let findings = [
            finding(pid: 100, parent: 90, name: "2.1.331", path: claude, args: ["claude"]),
            finding(pid: 90, parent: 100, name: "tmux"),
        ]

        // Act
        let instances = inspector().instances(from: findings)

        // Assert: it returns, and the loop does not make the agent its own
        // descendant.
        XCTAssertEqual(instances.map(\.id), ["pid:100"])
        XCTAssertEqual(instances[0].descendants.map(\.identity.pid), [90])
        XCTAssertEqual(instances[0].launchedBy, "tmux")
    }

    func testTagsSayHowTheAgentWasStarted() {
        XCTAssertEqual(AgentInspector.tags(kind: .claudeCode, arguments: ["claude", "-p", "--input-format", "stream-json"]), ["headless"])
        XCTAssertEqual(AgentInspector.tags(kind: .claudeCode, arguments: ["claude", "--chrome-native-host"]), ["Chrome native host"])
        XCTAssertEqual(AgentInspector.tags(kind: .claudeCode, arguments: ["claude"]), [])
        XCTAssertEqual(AgentInspector.tags(kind: .codex, arguments: ["codex", "exec", "fix the test"]), ["headless"])
        XCTAssertEqual(AgentInspector.tags(kind: .codex, arguments: ["codex", "-m", "gpt-5", "exec"]), ["headless"])
        XCTAssertEqual(AgentInspector.tags(kind: .codex, arguments: ["codex", "app-server", "--listen", "unix://x"]), ["app server"])
        XCTAssertEqual(AgentInspector.tags(kind: .codex, arguments: ["codex", "tell me what exec does"]), [])
    }

    func testTheMenuLineNamesTheDirectoryAndTheTotals() {
        // Arrange
        let findings = [
            finding(pid: 100, parent: 50, name: "2.1.331", path: claude, args: ["claude", "-p"], cpu: 20.25, memory: 400 * 1_048_576),
            finding(pid: 101, parent: 100, name: "node", args: ["node", "/x/mcp-server.js"], cpu: 5, memory: 12 * 1_048_576),
        ]

        // Act
        let instance = inspector(directories: [100: "/Users/me/workspace/killdeer"]).instances(from: findings)[0]

        // Assert
        XCTAssertEqual(instance.menuSummary, "Claude Code — killdeer — 2 processes — 25.2% CPU — 412 MB — [headless]")
        XCTAssertEqual(instance.descendants[0].menuSummary, "node mcp-server.js — 5.0% CPU — 12 MB")
    }

    func testASessionOfOneProcessWithNoReadableDirectory() {
        let findings = [finding(pid: 100, parent: 50, name: "2.1.331", path: claude, args: ["claude"], cpu: 1, memory: 1_048_576)]
        let instance = inspector().instances(from: findings)[0]
        XCTAssertNil(instance.directoryName)
        XCTAssertEqual(instance.menuSummary, "Claude Code — 1 process — 1.0% CPU — 1 MB")
    }

    func testALongProcessListIsCutWithTheAgentFirst() {
        // Arrange
        var findings = [finding(pid: 100, parent: 50, name: "2.1.331", path: claude, args: ["claude"])]
        for pid in 101...120 {
            findings.append(finding(pid: pid_t(pid), parent: 100, name: "worker", cpu: Double(pid)))
        }
        let instance = inspector().instances(from: findings)[0]

        // Act
        let listed = instance.listedProcesses(limit: 5)

        // Assert: the agent, then the busiest four.
        XCTAssertEqual(listed.shown.map(\.identity.pid), [100, 120, 119, 118, 117])
        XCTAssertEqual(listed.hidden, 16)
        XCTAssertEqual(instance.listedProcesses(limit: 50).hidden, 0)
    }
}

final class ProcessLookupTests: XCTestCase {
    func testReadsThisProcessesOwnDirectoryAndParent() throws {
        // Act
        let directory = ProcessLookup.workingDirectory(of: getpid())
        let process = try XCTUnwrap(ProcessLookup.kernelProcess(getpid()))

        // Assert
        XCTAssertEqual(directory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path)
        XCTAssertEqual(process.parentPID, getppid())
        XCTAssertFalse(process.name.isEmpty)
    }

    func testAnswersForARootOwnedProcessAndNotForAMissingOne() {
        // launchd is root's; proc_pidinfo refuses it, and this must not.
        XCTAssertEqual(ProcessLookup.kernelProcess(1)?.name, "launchd")
        XCTAssertNil(ProcessLookup.kernelProcess(999_999_999))
    }
}

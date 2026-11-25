# Killdeer

Killdeer finds CPU-heavy processes and disconnected Google Chrome helpers on macOS 14+, and doubles as a general load monitor: the menu bar shows how busy the CPU is and which processes are keeping it busy. It ships as a menu bar app and a command-line tool over the same `KilldeerCore` Swift package library.

Website: https://www.cyberneura.com/app/killdeer

## Installation

```sh
brew install --cask cyberneura/tap/killdeer
```

That installs both halves: `Killdeer.app` in `/Applications` and `killdeer` on your `PATH`. The cli is a symlink into the app bundle, so the two can never be different versions of each other.

Or build from source (see below).

## Menu bar app

Open Killdeer from Spotlight or Launchpad. It has no Dock icon; the item in the menu bar is the whole interface, and it turns red when something is running away. By default that item is the bird with a small upright meter beside it that fills with the system's CPU use, in steps of ten percent, so the load is visible without opening the menu.

The item also turns red when the whole machine is in trouble rather than one process: when the CPU has stayed at 95% or more for thirty seconds, and when macOS reports a thermal state of serious or critical, which is where it starts holding performance back to shed heat. The menu then carries a line saying which (`⚠ CPU stuck at full load`, `⚠ Thermal throttling`), and a notification is posted once when either begins. The CPU warning clears when the load falls below 85%.

Killdeer reads four figures, the **parameters**: the CPU use, the chip temperature, the memory in use, and the swap in use. Memory is what Activity Monitor calls Memory Used (app memory, wired and compressed, without the file cache) as a share of the installed RAM. Swap is drawn against the size of the RAM rather than against the swap files' current size: macOS grows those files as they fill, so a share of their size sits near the top whenever there is any swap and drops just as things get worse. A menu bar picture has room for one or two of the four, or for up to four in the history graph, so **Settings…** holds an order for them, and each style shows as many as it has places for, starting from the top. The order starts as CPU, temperature, memory, swap. The menu always lists them all, in that order, and names the part of the picture each one is drawn in, as in `CPU 12.3% — outer ring`.

**Menu Bar Style**, in the menu and in **Settings…**, swaps the picture for another:

| Style | Shows |
|---|---|
| Bird and gauge | The first parameter, as a gauge that fills from the bottom |
| Ring gauge | The first parameter on the outer ring and the second on the inner one; both fill clockwise from seven o'clock round to five, like a speedometer |
| Flapping bird | The first parameter, as how fast the bird beats its wing; it sits still at zero |
| Core bars | One upright bar per core, so a single core pegged by one process stands out from an evenly busy machine. Always the CPU |
| Core heatmap | One tile per core, darker the busier, and a thin meter at the right-hand edge for the first parameter that is not the CPU |
| Moon phase | The first parameter: a new moon at the bottom of the scale, full at the top |
| Weather | The first parameter, from sun through cloud and rain to thunder |
| Coffee cup | The first parameter fills the cup, which spills over at the top of the scale; the second sets how much it steams |
| History graph | The last thirty readings (five minutes at the default interval) of the first two, three or four parameters, newest at the right, one row each; the row count is in **Settings…** and starts at four |

The two per-core styles are pictures of the cores, which only the CPU has, so the order does not change what their bars and tiles show. The history graph keeps its readings whatever style is chosen, so switching to it shows the minutes already gone; a reading that was not taken leaves a gap. With two rows a row has seven steps; with three or four it has ten or eight, in half points, which a display with one pixel to the point shows a little soft. Temperatures are drawn on a scale from 30 to 100 °C. On a Mac with no readable sensor the temperature is passed over: the next parameter in the order takes its place in the picture, and the menu has no line for it. Apart from the cores and the history, every figure is quantised to ten steps, and every style turns red for a runaway. The two per-core styles average neighbouring cores in groups on a machine with more than sixteen, so the item never runs to half the menu bar. The style, the order and the row count are kept across launches.

Putting memory first makes for a quiet picture: macOS keeps memory 60 to 85% full on a healthy Mac, so the weather stays at rain and the bird never rests.

Below the parameters the menu carries a **Top Processes** list of the busiest processes of any kind (runaway or not, Chrome or not; up to five, those under 1% left out) with a kill behind a second press on each, the scan and cleanup actions, a **Chrome Instances** submenu holding the same per-instance summary the `chrome` command prints with a kill behind a second press, an **AI Agents** submenu with a row per running Claude Code or Codex session (described under `agents` below), and a way into Activity Monitor when you want more than Killdeer shows. The temperature is the hottest of the SoC die sensors, or, on a machine that exposes none, the hottest sensor it does offer — which may be the SSD or the battery rather than the chip. It comes from the HID sensors macOS publishes without any special permission; that is not a public interface, so hardware offering nothing readable drops the temperature and leaves the other figures in place.

**Start at Login** in that menu registers the app with macOS through `SMAppService`. The registration belongs to the system rather than to Killdeer, so it can also be revoked in System Settings > General > Login Items; the menu reads the state back from macOS and follows it.

## Build

```sh
swift build -c release          # bare executables in .build/release
scripts/make-app.sh             # dist/Killdeer.app, universal, unsigned
scripts/make-dmg.sh             # dist/Killdeer_<version>_universal.dmg
```

`make-app.sh` is what produces a fully working app: `SMAppService` and notifications both need a real bundle, and `swift run killdeer-app` only approximates one. `LSUIElement` is the part that does survive a bare executable, through the `Info.plist` linked into it (see `Package.swift`). Both scripts take `--sign "Developer ID Application: ..."`; the release workflow passes it, and a local build has no certificate to pass.

`scripts/make-icon.sh` re-renders `packaging/AppIcon.png` from `packaging/AppIcon.svg` and needs `librsvg`. Run it when the icon changes, then run `scripts/generate-macos-icons.sh` (macOS with Xcode) to rebuild `packaging/icons/`, and commit the results. See `resources/app-icons/README.md`.

Killdeer uses only Apple frameworks (`Foundation`, `AppKit`, `SwiftUI`, `ServiceManagement`, `IOKit`, and Darwin/libproc) and needs no special permission to inspect or signal processes owned by the same user.

## Releasing

`VERSION` decides releases: on every push to main the workflow asks whether the version in that file is already published, and builds, signs, notarizes and publishes it if it is not. So a push that leaves an unpublished version in place still releases it, and re-pushing a published one does nothing. `scripts/release.sh [patch|minor|major]` picks the next number, pushes it and follows the run.

## Usage

```sh
# Show detected runaway processes (80% CPU threshold, one-second sample)
killdeer scan

# Show all sampled processes
killdeer scan --all

# Show the busiest processes, whatever they are (top 5 by default)
killdeer top
killdeer top --limit 10

# Customize CPU threshold and sampling interval
killdeer scan --cpu 50 --interval 2

# Kill explicitly selected processes
killdeer kill 1234 5678

# Find orphan Chrome helpers, show them, and ask before cleaning
killdeer clean-chrome

# Non-interactive one-shot cleanup
killdeer clean-chrome --yes

# List running Chromium-family browsers, one line per instance
killdeer chrome

# Add a row per helper process
killdeer chrome --all

# Check that each debugging port actually answers
killdeer chrome --probe

# Machine-readable, with every field always present
killdeer chrome --json

# Take down the instance a PID belongs to
killdeer chrome kill 43420

# List running Claude Code and Codex sessions, with what each has started
killdeer agents

# Add a row per process
killdeer agents --all
```

`chrome` answers "which browser is my automation actually driving". For each
running instance it reports the profile display name and signed-in account, the
user-data-dir, whether it is headless, its debugging port, the automation
switches it was started with, and the program that launched it. Helpers are
folded into the browser they descend from; helpers whose browser is gone are
listed separately as orphaned, with an unknown profile.

A browser told to choose its own port with `--remote-debugging-port=0` is
reported with the port it settled on, read back from `DevToolsActivePort`.
`--probe` goes one step further and asks the endpoint for its version, which is
the difference between a port that was requested and one that is listening.

A port is only reported as a browser's once that browser is found holding it.
The switch is a request: the bind can fail, and something else can be there,
including an Electron app started with its own debugging port, which this
command does not list. Probes go to the socket the browser holds, address family
included, because with another process on `127.0.0.1:9222` a browser still binds
`[::1]:9222` and asking by port number alone reaches the wrong one.

Two browsers both holding the same port are marked as contesting it, and neither
is probed. They end up one per address family, so which one a client reaches
depends on how that client resolves localhost. Naming either as the one
answering would be the guess this command exists to avoid.

Identification is by the `.app` bundle in the path the kernel recorded as
executed, not `argv[0]`, which is only what the parent chose to pass. Electron
apps ship the same Chromium helpers, so matching on process name would list a
code editor as a browser.

A browser started without `--profile-directory` is reported against the profile
it used last, read from `Local State`. One browser process can hold several
profiles open at once; only that one is named.

The crash handler is placed by the `--database` directory it writes to, falling
back to the installation it was launched from. Crashpad double-forks it onto
launchd, so its parent link says nothing about which browser it serves, and
going by the parent alone would show a stray helper beside every healthy
browser. One handler serves a whole installation, so when several browsers are
running out of the same one it is reported under none of them rather than under
a guess.

`agents` answers "which of my agent sessions is the machine working for". Every
Claude Code or Codex process that was not started by another agent is a
session, and everything under it is counted with it: MCP servers, the shell
commands it runs, a build, a browser it launched, and an agent it started in
turn (`codex exec` from a Claude Code session is part of that session). For
each one it reports the directory the agent works in, which is the project the
session is about (for Codex, the one given with `-C` when there is one), the
app it was started from (the terminal or editor, not the
shell in between), whether it is headless or a server, and the CPU and memory
of the whole group. The menu's **AI Agents** submenu holds a line per session
such as `Claude Code — killdeer — 3 processes — 25.3% CPU — 412 MB`, and under
it the processes, busiest first, each with a kill behind a second press.

An agent is identified by the file the kernel recorded as executed: `claude`,
`codex`, or node or bun running either package's script. The process name is
no use for this, because Claude Code's installer links `claude` to a file
named after its version and the process is reported under that name. That
same file is also Claude Code's search tools, started under another name
(`ugrep`, `rg`, `bfs`); those are listed as processes of the session under
that name. The desktop apps are not listed as sessions; a session one of them
runs is.

A process that has detached from its session, by double-forking onto launchd,
has no parent link back to it and is counted with none. Like the rest of
Killdeer, the list holds what the current user may read, which leaves out
other users' sessions.

Termination is deliberately two-stage: `SIGTERM`, a three-second grace period, then `SIGKILL` if the process remains alive. Killdeer checks the process start time before each signal stage so a recycled PID is never targeted.

## Detection model

CPU usage is computed from two `PROC_PIDTASKINFO` snapshots. Reaching the configured threshold contributes 50 points. A Chrome helper whose parent is missing or whose ancestry no longer reaches the main Google Chrome process contributes 40 points; active CPU use adds another 20. A score of 50 or greater is reported by `scan`.

`top` and the menu's **Top Processes** list skip this scoring: they rank by CPU alone, so they show a busy machine's culprits before any of them counts as a runaway. Both list only processes Killdeer can read, which without elevated privileges means those owned by the same user; system daemons such as `WindowServer` or `kernel_task` do not appear, though their load still shows in the overall CPU figure and the meter.

Orphan status alone is intentionally below the runaway threshold to avoid false alarms, but `clean-chrome` lists and cleans all disconnected Chrome helpers because that command is an explicit user action.

## License

Killdeer is released under the [MIT License](LICENSE).

## Third-party licenses

[THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt) lists the open source libraries Killdeer bundles. At present there are none: Killdeer has no package dependencies and links only Apple system frameworks, which are part of macOS.

The same text, preceded by Killdeer's own license, is compiled into both executables. Read it with `killdeer --license`, or from **Third-Party Licenses…** in the menu bar app's menu.

The file is generated, together with `Sources/KilldeerCore/Licenses.swift` which embeds it. After adding a dependency or changing `LICENSE`, run

```sh
scripts/generate-third-party-notices.sh
```

and commit both files. The release workflow runs it with `--check` and fails if either is stale.

# Killdeer

Killdeer finds CPU-heavy processes and disconnected Google Chrome helpers on macOS 14+, and doubles as a general load monitor: the menu bar shows how busy the CPU is and which processes are keeping it busy. It ships as a menu bar app and a command-line tool over the same `KilldeerCore` Swift package library.

## Installation

```sh
brew install --cask cyberneura/tap/killdeer
```

That installs both halves: `Killdeer.app` in `/Applications` and `killdeer` on your `PATH`. The cli is a symlink into the app bundle, so the two can never be different versions of each other.

Or build from source (see below).

## Menu bar app

Open Killdeer from Spotlight or Launchpad. It has no Dock icon; the item in the menu bar is the whole interface, and it turns red when something is running away. By default that item is the bird with a small upright meter beside it that fills with the system's CPU use, in steps of ten percent, so the load is visible without opening the menu.

**Menu Bar Style**, in the menu and in **Settings…**, swaps that picture for another way of showing the same load: a ring gauge that fills clockwise from seven o'clock round to five, like a speedometer; the bird on its own, beating its wing faster the busier the machine is and sitting still when it is idle; one upright bar per core, so a single core pegged by one process stands out from an evenly busy machine; a heatmap of one tile per core, darker the busier; the moon, new when idle and full at full load; the weather, from sun through cloud and rain to thunder; or a coffee cup that fills and steams, and spills over at full load. Every style is drawn from the same reading, quantised to ten steps, and every one turns red for a runaway. The two per-core styles average neighbouring cores in groups on a machine with more than sixteen, so the item never runs to half the menu bar. The choice is kept across launches.

The menu carries the system's CPU use and a temperature, a **Top Processes** list of the busiest processes of any kind (runaway or not, Chrome or not; up to five, those under 1% left out) with a kill behind a second press on each, the scan and cleanup actions, a **Chrome Instances** submenu holding the same per-instance summary the `chrome` command prints with a kill behind a second press, and a way into Activity Monitor when you want more than Killdeer shows. The temperature is the hottest of the SoC die sensors, or, on a machine that exposes none, the hottest sensor it does offer — which may be the SSD or the battery rather than the chip. It comes from the HID sensors macOS publishes without any special permission; that is not a public interface, so hardware offering nothing readable drops the temperature and leaves the CPU figure in place.

**Start at Login** in that menu registers the app with macOS through `SMAppService`. The registration belongs to the system rather than to Killdeer, so it can also be revoked in System Settings > General > Login Items; the menu reads the state back from macOS and follows it.

## Build

```sh
swift build -c release          # bare executables in .build/release
scripts/make-app.sh             # dist/Killdeer.app, universal, unsigned
scripts/make-dmg.sh             # dist/Killdeer_<version>_universal.dmg
```

`make-app.sh` is what produces a fully working app: `SMAppService` and notifications both need a real bundle, and `swift run killdeer-app` only approximates one. `LSUIElement` is the part that does survive a bare executable, through the `Info.plist` linked into it (see `Package.swift`). Both scripts take `--sign "Developer ID Application: ..."`; the release workflow passes it, and a local build has no certificate to pass.

`scripts/make-icon.sh` re-renders `packaging/AppIcon.png` from `packaging/AppIcon.svg` and needs `librsvg`. Run it when the icon changes and commit the png.

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

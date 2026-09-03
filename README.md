# Killdeer

Killdeer finds CPU-heavy processes and disconnected Google Chrome helpers on macOS 14+. It ships as a menu bar app and a command-line tool over the same `KilldeerCore` Swift package library.

## Installation

```sh
brew install --cask cyberneura/tap/killdeer
```

That installs both halves: `Killdeer.app` in `/Applications` and `killdeer` on your `PATH`. The cli is a symlink into the app bundle, so the two can never be different versions of each other.

Or build from source (see below).

## Menu bar app

Open Killdeer from Spotlight or Launchpad. It has no Dock icon and no window; the bird in the menu bar is the whole interface, and it turns red when something is running away.

The menu carries the system's CPU use and a temperature, the scan and cleanup actions, and a way into Activity Monitor when you want more than Killdeer shows. The temperature is the hottest of the SoC die sensors, or, on a machine that exposes none, the hottest sensor it does offer — which may be the SSD or the battery rather than the chip. It comes from the HID sensors macOS publishes without any special permission; that is not a public interface, so hardware offering nothing readable drops the temperature and leaves the CPU figure in place.

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

# Customize CPU threshold and sampling interval
killdeer scan --cpu 50 --interval 2

# Kill explicitly selected processes
killdeer kill 1234 5678

# Find orphan Chrome helpers, show them, and ask before cleaning
killdeer clean-chrome

# Non-interactive one-shot cleanup
killdeer clean-chrome --yes
```

Termination is deliberately two-stage: `SIGTERM`, a three-second grace period, then `SIGKILL` if the process remains alive. Killdeer checks the process start time before each signal stage so a recycled PID is never targeted.

## Detection model

CPU usage is computed from two `PROC_PIDTASKINFO` snapshots. Reaching the configured threshold contributes 50 points. A Chrome helper whose parent is missing or whose ancestry no longer reaches the main Google Chrome process contributes 40 points; active CPU use adds another 20. A score of 50 or greater is reported by `scan`.

Orphan status alone is intentionally below the runaway threshold to avoid false alarms, but `clean-chrome` lists and cleans all disconnected Chrome helpers because that command is an explicit user action.

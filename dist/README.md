# Killdeer

Killdeer is a macOS 14+ command-line MVP for finding CPU-heavy processes and disconnected Google Chrome helpers. Its monitoring and termination logic lives in the reusable `KilldeerCore` Swift package library, ready for a later `MenuBarExtra` app.

## Build

```sh
swift build -c release
```

The executable is written to `.build/release/killdeer`. Killdeer uses only Apple frameworks (`Foundation`, `AppKit`, and Darwin/libproc) and needs no special permission to inspect or signal processes owned by the same user.

## Installation

```sh
brew install cyberneura/tap/killdeer
```

Or build from source (see below).

## Usage

```sh
# Show detected runaway processes (80% CPU threshold, one-second sample)
swift run killdeer scan

# Show all sampled processes
swift run killdeer scan --all

# Customize CPU threshold and sampling interval
swift run killdeer scan --cpu 50 --interval 2

# Kill explicitly selected processes
swift run killdeer kill 1234 5678

# Find orphan Chrome helpers, show them, and ask before cleaning
swift run killdeer clean-chrome

# Non-interactive one-shot cleanup
swift run killdeer clean-chrome --yes
```

Termination is deliberately two-stage: `SIGTERM`, a three-second grace period, then `SIGKILL` if the process remains alive. Killdeer checks the process start time before each signal stage so a recycled PID is never targeted.

## Detection model

CPU usage is computed from two `PROC_PIDTASKINFO` snapshots. Reaching the configured threshold contributes 50 points. A Chrome helper whose parent is missing or whose ancestry no longer reaches the main Google Chrome process contributes 40 points; active CPU use adds another 20. A score of 50 or greater is reported by `scan`.

Orphan status alone is intentionally below the runaway threshold to avoid false alarms, but `clean-chrome` lists and cleans all disconnected Chrome helpers because that command is an explicit user action.

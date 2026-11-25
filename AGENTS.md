# Killdeer

A macOS menu bar app (SwiftUI `MenuBarExtra`) and CLI that watch the CPU and find runaway processes. Swift Package Manager, no Xcode project. See README.md for usage and DESIGN.md for design decisions.

## Layout

- `Sources/KilldeerCore`: everything testable without a screen (sampling, detection, the arithmetic behind each menu bar picture). Tests live in `Tests/KilldeerCoreTests`.
- `Sources/KilldeerApp`: the menu bar app. Drawing (`MeterArt`) and SwiftUI views only.
- `Sources/KilldeerCLI`: the `killdeer` command.

## Commands

`.j-menu.yaml` has an entry for each of these (type `j`).

```shell
swift build
swift test
swift run killdeer-app --interval 2   # debug run; Ctrl-C to quit
scripts/make-app.sh                   # dist/Killdeer.app (universal, unsigned)
```

## Things the code does not tell you

- A debug run (`swift run killdeer-app`) is a bare executable, not an .app. Notifications and Start at Login are skipped there, so check them with `scripts/make-app.sh`.
- A debug run and the installed app share the user defaults domain `com.cyberneura.killdeer`. Changing the menu bar style in one changes it in the other. Both are processes named `killdeer-app`, so quit the installed one first or there are two items in the menu bar.
- Do not hold `ObservableObject`s as `@StateObject` in the `App`. Any published change then invalidates the whole scene, the menu is rebuilt, and an open submenu closes on every reading. Only the view that draws a value should observe it (`MenuBarLabel` for the picture, `MenuContent` for the menu).
- The menu bar item may be hidden by a menu bar manager, so a screenshot can miss it. To check a `MeterArt` change, render `MeterArt.image(for:)` offscreen at 8–10× instead: copy every file of `Sources/KilldeerCore` plus `MeterArt.swift` and `KilldeerBird.swift` into a scratch directory, delete the `import KilldeerCore` lines, and compile them with `swiftc` together with a small `main.swift` that builds a `MeterFrame` and writes the image to a PNG. The Settings window can be checked the same way, with every file of `Sources/KilldeerApp` but `KilldeerApp.swift` and an `NSHostingView` of `SettingsView` drawn through `cacheDisplay`.

## Releasing

Merging a change to `VERSION` into main releases it: the Release workflow builds, signs, notarizes and publishes any version not yet released. Bump the minor version for a feature and the patch version for a fix, in the same pull request.

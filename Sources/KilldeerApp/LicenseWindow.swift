import AppKit
import KilldeerCore

/// The window behind the menu's Third-Party Licenses item: Killdeer's own
/// license followed by the notices for what it bundles, read-only and
/// selectable. The text is compiled in (KilldeerCore's `Licenses`), so the
/// window shows what this build shipped with rather than whatever a file on
/// disk says.
@MainActor
enum LicenseWindow {
    // Kept so that a second press brings the open window forward instead of
    // stacking another one, and so that the window outlives the menu action
    // that created it.
    private static var window: NSWindow?

    static func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        // Killdeer is an LSUIElement app with no Dock icon; without activating
        // it the window opens behind whatever the user was working in. The
        // menu click is what makes this activation one macOS will honour.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Third-Party Licenses"
        // Owned by the static `window`, which reopens it after a close; the
        // default of true would free it out from under that reference.
        window.isReleasedWhenClosed = false

        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            textView.textContainerInset = NSSize(width: 12, height: 12)
            textView.string = Licenses.license + "\n" + Licenses.thirdPartyNotices
        }
        window.contentView = scrollView
        window.center()
        return window
    }
}

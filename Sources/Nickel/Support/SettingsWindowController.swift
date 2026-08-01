import AppKit
import SwiftUI

/// Owns the single "Nickel Settings" window, created lazily on first
/// `show()` and reused afterwards (never recreated, so repeated ⌘,/menu
/// opens can't spawn duplicates). `isReleasedWhenClosed = false` keeps the
/// window (and this controller, held by the `shared` singleton) alive across
/// closes, matching how System Settings panes behave.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private convenience init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Nickel Settings"
        // Settings windows minimize but never resize (the content sizes
        // itself, via `SettingsView`'s `.fixedSize()`), so `.resizable` is
        // deliberately left out.
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        // `setFrameAutosaveName` restores a previously-saved window position
        // (and returns `false` when there wasn't one), so `center()` only
        // runs the first time the window is ever shown.
        let restoredSavedFrame = window.setFrameAutosaveName("NickelSettings")
        if !restoredSavedFrame {
            window.center()
        }
        self.init(window: window)
    }

    /// Single call site used by the status item menu, the panel's ⋯ menu,
    /// and ⌘, in `FloatingPanel`. Activates first so the window comes up
    /// key and in front even when Nickel wasn't the active app.
    func show() {
        guard let window else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

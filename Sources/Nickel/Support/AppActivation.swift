import AppKit

/// Cooperative activation (macOS 14+): ask the frontmost app to yield.
/// `activate(from:)` names the yielding app, which the system honors far
/// more often than a bare request; the bare `activate()` remains a
/// fallback. Replaces the deprecated `activate(ignoringOtherApps:)`, whose
/// "ignoring" promise cooperative activation no longer keeps.
enum AppActivation {
    static func activate() {
        guard !NSApp.isActive else { return }
        if let front = NSWorkspace.shared.frontmostApplication,
           front != .current,
           NSRunningApplication.current.activate(from: front, options: []) {
            return
        }
        NSApp.activate()
    }
}

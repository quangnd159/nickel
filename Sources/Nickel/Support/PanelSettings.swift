import Foundation

/// Persisted "Keep Panel on Top" preference, read/written from the panel's
/// ⋯ menu and the Settings window and applied live to `FloatingPanel`'s
/// window level. Mirrors `LaunchAtLogin`'s thin-`UserDefaults`-wrapper shape
/// rather than an `ObservableObject`, since it's read from both AppKit
/// (`FloatingPanel`) and SwiftUI (`PanelView`, `SettingsView`) call sites.
enum PanelSettings {
    private static let keepOnTopDefaultsKey = "keepPanelOnTop"

    /// Posted whenever `keepPanelOnTop` changes, so `FloatingPanel` can apply
    /// the new window level immediately instead of only at next launch.
    static let keepOnTopDidChange = Notification.Name("NickelKeepOnTopDidChange")

    private static let showMenuBarIconDefaultsKey = "showMenuBarIcon"

    /// Posted whenever `showMenuBarIcon` changes, so `AppDelegate` can show
    /// or hide the status item immediately.
    static let showMenuBarIconDidChange = Notification.Name("NickelShowMenuBarIconDidChange")

    /// Whether the status item is shown. Off is for hotkey-first users; the
    /// app stays reachable via double-shift, the Dock icon, or by
    /// relaunching it, which shows the panel.
    static var showMenuBarIcon: Bool {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: showMenuBarIconDefaultsKey) != nil else { return true }
            return defaults.bool(forKey: showMenuBarIconDefaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: showMenuBarIconDefaultsKey)
            NotificationCenter.default.post(name: showMenuBarIconDidChange, object: nil)
        }
    }

    static var keepPanelOnTop: Bool {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: keepOnTopDefaultsKey) != nil else { return true }
            return defaults.bool(forKey: keepOnTopDefaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: keepOnTopDefaultsKey)
            NotificationCenter.default.post(name: keepOnTopDidChange, object: nil)
        }
    }

}

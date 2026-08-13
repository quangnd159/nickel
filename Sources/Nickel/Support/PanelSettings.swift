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

    private static let captureKeyDefaultsKey = "captureModifierKey"
    private static let panelToggleKeyDefaultsKey = "panelToggleModifierKey"

    static let defaultCaptureKey: ModifierKey = .leftShift
    static let defaultPanelToggleKey: ModifierKey = .rightShift

    /// Posted whenever `captureKey` changes, including as the side effect of
    /// a swap triggered by setting `panelToggleKey`.
    static let captureKeyDidChange = Notification.Name("NickelCaptureKeyDidChange")

    /// Posted whenever `panelToggleKey` changes, including as the side
    /// effect of a swap triggered by setting `captureKey`.
    static let panelToggleKeyDidChange = Notification.Name("NickelPanelToggleKeyDidChange")

    /// Which physical modifier key's double-tap triggers capture. Falls back
    /// to the default when nothing is stored, or the stored value doesn't
    /// match a known key.
    static var captureKey: ModifierKey {
        get {
            let defaults = UserDefaults.standard
            guard let raw = defaults.string(forKey: captureKeyDefaultsKey), let key = ModifierKey(rawValue: raw) else {
                return defaultCaptureKey
            }
            return key
        }
        set {
            let defaults = UserDefaults.standard
            // The two actions must never share a key: assigning the other
            // action's key here swaps them, the way System Settings resolves
            // a keyboard shortcut conflict, instead of leaving both actions
            // on the same key.
            if newValue == panelToggleKey {
                let displaced = captureKey
                defaults.set(newValue.rawValue, forKey: captureKeyDefaultsKey)
                defaults.set(displaced.rawValue, forKey: panelToggleKeyDefaultsKey)
                NotificationCenter.default.post(name: captureKeyDidChange, object: nil)
                NotificationCenter.default.post(name: panelToggleKeyDidChange, object: nil)
            } else {
                defaults.set(newValue.rawValue, forKey: captureKeyDefaultsKey)
                NotificationCenter.default.post(name: captureKeyDidChange, object: nil)
            }
        }
    }

    /// Which physical modifier key's double-tap toggles the panel. See
    /// `captureKey` for the fallback and swap-on-conflict rules, which are
    /// symmetric between the two settings.
    static var panelToggleKey: ModifierKey {
        get {
            let defaults = UserDefaults.standard
            guard let raw = defaults.string(forKey: panelToggleKeyDefaultsKey), let key = ModifierKey(rawValue: raw) else {
                return defaultPanelToggleKey
            }
            return key
        }
        set {
            let defaults = UserDefaults.standard
            if newValue == captureKey {
                let displaced = panelToggleKey
                defaults.set(newValue.rawValue, forKey: panelToggleKeyDefaultsKey)
                defaults.set(displaced.rawValue, forKey: captureKeyDefaultsKey)
                NotificationCenter.default.post(name: panelToggleKeyDidChange, object: nil)
                NotificationCenter.default.post(name: captureKeyDidChange, object: nil)
            } else {
                defaults.set(newValue.rawValue, forKey: panelToggleKeyDefaultsKey)
                NotificationCenter.default.post(name: panelToggleKeyDidChange, object: nil)
            }
        }
    }
}

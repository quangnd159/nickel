import AppKit

let app = NSApplication.shared

// `NICKEL_UI_PROBE=1` runs the note list's geometry checks instead of the app
// (see `UIProbe`): no status item, no hotkey monitor, no Accessibility grant.
if UIProbe.isEnabled {
    let probe = UIProbeDelegate()
    app.setActivationPolicy(.accessory)
    app.delegate = probe
    app.run()
} else {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

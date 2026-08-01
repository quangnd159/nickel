import AppKit

/// Builds the status item's icon: a single filled shift-arrow glyph, echoing
/// the app's double-shift mark without the clipping a two-symbol composite
/// suffered in the real menu bar (its wider frame got cut on both sides).
/// `isTemplate = true` lets AppKit adapt it to menu bar appearance
/// (light/dark, tinted/selected) the same way any `NSImage(systemSymbolName:)`
/// icon does.
enum StatusItemIcon {
    static func make() -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        guard
            let image = NSImage(systemSymbolName: "shift.fill", accessibilityDescription: "Nickel")?
                .withSymbolConfiguration(config)
        else {
            return nil
        }

        image.isTemplate = true
        return image
    }
}

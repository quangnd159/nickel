import AppKit
import SwiftUI

/// Makes the top bar drag the window like a title bar.
///
/// `FloatingPanel` sets `isMovableByWindowBackground = true`, but the panel's
/// background has its own tap gesture (`handleBackgroundClick`, for
/// deselecting notes), which swallows the mouse-down SwiftUI would otherwise
/// need to fall through to AppKit's window-drag handling. Rather than thread
/// drag detection through that gesture, this gives the top bar its own
/// dedicated AppKit drag handle — the same "AppKit for window-level mouse
/// behavior" approach as `ComposerDropView.swift`.
///
/// Placed as a `.background` of the top bar, it spans the top bar's area but
/// draws nothing and sits behind the search field, section menu, and ⋯ menu,
/// so it only ever receives mouse-downs that land on the bar's empty space.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleView { DragHandleView() }
    func updateNSView(_ nsView: DragHandleView, context: Context) {}

    final class DragHandleView: NSView {
        // `performDrag(with:)` is the documented way to hand a mouse-down to
        // the window's own drag handling: it gives screen-edge behavior,
        // Stage Manager/tiling, and multi-space dragging for free, matching
        // what a real title bar does. No double-click handling — a borderless
        // floating panel isn't expected to zoom or minimize on double-click.
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

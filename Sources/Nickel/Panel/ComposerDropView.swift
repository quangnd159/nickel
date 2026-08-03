import AppKit
import SwiftUI

/// The composer card's drop target, implemented as an AppKit drag
/// destination rather than SwiftUI's `.onDrop`.
///
/// SwiftUI's drop providers erase a text-like file's file-ness: a `.txt` or
/// `.json` dragged from Finder arrives as a bare `public.plain-text`
/// provider with no file URL and no `suggestedName`, indistinguishable from
/// a dragged text selection — and the raw drag pasteboard read outside a
/// dragging session hands back unresolvable file-reference URLs. Inside the
/// sanctioned `NSDraggingInfo` session, `draggingPasteboard` resolves real
/// file URLs for every file type, so the standard AppKit destination is the
/// reliable (and simplest) layer to accept drops on.
///
/// Placed as a `.background` of the card, it spans the card's full area but
/// draws nothing and never participates in mouse handling — it exists only
/// for the dragging protocol. The composer field editor accepts no drags
/// (see `FloatingPanel.windowWillReturnFieldEditor`), so this view is the
/// card's single drag destination.
struct ComposerDropTarget: NSViewRepresentable {
    @Binding var isTargeted: Bool

    /// Real path URLs of dropped files, every file type, in drag order.
    var onFileURLs: ([URL]) -> Void
    /// Dropped text content (a dragged selection, not a file).
    var onText: (String) -> Void
    /// Raw dropped image data with no backing file (e.g. a screenshot
    /// dragged straight off a capture tool).
    var onImageData: (Data) -> Void

    func makeNSView(context: Context) -> DropCatcherView {
        let view = DropCatcherView()
        view.onTargeted = { targeted in isTargeted = targeted }
        view.onFileURLs = onFileURLs
        view.onText = onText
        view.onImageData = onImageData
        return view
    }

    func updateNSView(_ view: DropCatcherView, context: Context) {
        view.onTargeted = { targeted in isTargeted = targeted }
        view.onFileURLs = onFileURLs
        view.onText = onText
        view.onImageData = onImageData
    }

    final class DropCatcherView: NSView {
        var onTargeted: ((Bool) -> Void)?
        var onFileURLs: (([URL]) -> Void)?
        var onText: ((String) -> Void)?
        var onImageData: ((Data) -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([.fileURL, .string, .png, .tiff])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        // Drags only; clicks fall through to the card's real content.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            onTargeted?(true)
            return .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            onTargeted?(false)
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            onTargeted?(false)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let pasteboard = sender.draggingPasteboard

            if let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL], !urls.isEmpty {
                onFileURLs?(urls)
                return true
            }

            if let text = pasteboard.string(forType: .string), !text.isEmpty {
                onText?(text)
                return true
            }

            if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
                onImageData?(data)
                return true
            }

            return false
        }
    }
}

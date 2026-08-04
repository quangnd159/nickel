import AppKit
import Combine
import SwiftUI

/// Posted by `PanelActions.editInNewWindow` (⌘↩ / the note context menu)
/// with the note's `UUID` as the object. `AppDelegate` observes it and
/// forwards to `NoteEditorWindowManager` — the panel can't reach app-level
/// window ownership directly, the same reason `.nickelClosePanel` exists.
extension Notification.Name {
    static let nickelEditNoteInNewWindow = Notification.Name("NickelEditNoteInNewWindow")
}

/// Owns the standalone note-editing windows, one per note. Held by
/// `AppDelegate`.
final class NoteEditorWindowManager {
    private let store: NoteStore
    private var controllers: [UUID: NoteEditorWindowController] = [:]

    /// Top-left for the next window that has no remembered frame; each such
    /// window steps down-right from the last, like `NSDocumentController`'s
    /// cascade. `NSZeroPoint` means "wherever the window already is."
    private var cascadePoint: NSPoint = .zero

    init(store: NoteStore) {
        self.store = store
    }

    /// Opens `noteID`'s editing window, or focuses the one already open for
    /// it — a note never gets a second window, matching Apple Notes' "Open
    /// Note in Separate Window."
    func open(noteID: UUID) {
        guard let note = store.notes.first(where: { $0.id == noteID }) else { return }

        if let existing = controllers[noteID] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = NoteEditorWindowController(note: note, store: store)
        controller.onClose = { [weak self] in self?.controllers[noteID] = nil }
        controllers[noteID] = controller

        if let window = controller.window {
            let autosaveName = "NoteEditor-\(noteID.uuidString)"
            window.setFrameAutosaveName(autosaveName)
            // `setFrameAutosaveName` only arranges *future* saves; restoring
            // is `setFrameUsingName`, which returns false when this note has
            // no remembered frame yet. Only then is a placement decision ours
            // to make, so a remembered frame is never cascaded away from.
            if !window.setFrameUsingName(autosaveName) {
                window.center()
                cascadePoint = window.cascadeTopLeft(from: cascadePoint)
            }
        }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

/// One note's editing window: a plain titled document window (deliberately
/// not a panel and not floating — the panel is what floats above it when
/// keep-on-top is set).
final class NoteEditorWindowController: NSWindowController, NSWindowDelegate {
    private let noteID: UUID
    private var noteObserver: AnyCancellable?

    /// Called from `windowWillClose` so the manager can drop its registry
    /// entry. The manager captures itself weakly when setting this, so the
    /// manager → controller → closure chain isn't a cycle.
    var onClose: (() -> Void)?

    init(note: Note, store: NoteStore) {
        noteID = note.id

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 320, height: 200)
        window.backgroundColor = .textBackgroundColor
        // These windows are pure views onto store data, recreated on demand
        // from the panel; there's no restoration class to rebuild one at
        // launch, so opting out beats a half-restored empty window.
        window.isRestorable = false
        window.contentView = NSHostingView(
            rootView: NoteEditorView(noteID: note.id, initialText: note.text)
                .environmentObject(store)
        )

        super.init(window: window)

        window.delegate = self
        applyTitle(for: note)

        noteObserver = store.$notes.sink { [weak self] notes in
            self?.noteDidChange(to: notes.first { $0.id == note.id })
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The note's title/subtitle follow its text and section live. A note
    /// deleted out from under the window (from the panel, or by clearing
    /// done notes) closes it.
    private func noteDidChange(to note: Note?) {
        guard let note else {
            // This fires from `@Published`'s `willSet` — mid-mutation, before
            // SwiftUI has seen the change — so tearing the hosting view down
            // right here would run inside that update. Next runloop turn is
            // soon enough.
            DispatchQueue.main.async { [weak self] in self?.close() }
            return
        }
        applyTitle(for: note)
    }

    private func applyTitle(for note: Note) {
        window?.title = NoteEditorTitle.title(for: note.text)
        window?.subtitle = note.listName ?? ""
    }

    func windowWillClose(_ notification: Notification) {
        noteObserver = nil
        onClose?()
    }
}

/// Derives an editing window's title from a note's Markdown source.
enum NoteEditorTitle {
    /// The note's first non-blank line as plain text: block markers (`#`,
    /// `-`, `>`) and inline styling (`**bold**`, links) both stripped, the
    /// way Apple Notes titles a note's separate window. A note with no text
    /// yet gets a placeholder rather than a blank title bar.
    static func title(for text: String) -> String {
        let firstLine = MarkdownBlock.parse(text)
            .lazy
            .map(\.plainText)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let firstLine else { return "New Note" }

        let plain = String(MarkdownCache.inline(for: firstLine).characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.isEmpty ? "New Note" : plain
    }
}

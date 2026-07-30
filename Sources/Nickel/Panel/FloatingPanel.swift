import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    private let selectionModel = SelectionModel()
    private var panelActions: PanelActions?

    convenience init(store: NoteStore) {
        let size = NSSize(width: 360, height: 560)
        self.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        let actions = PanelActions(store: store, selection: selectionModel)
        panelActions = actions

        contentView = NSHostingView(
            rootView: PanelView()
                .environmentObject(store)
                .environmentObject(selectionModel)
                .environmentObject(actions)
        )

        positionNearTopRight()
    }

    override var canBecomeKey: Bool { true }

    private func positionNearTopRight() {
        guard let screen = NSScreen.main else { return }
        let margin: CGFloat = 40
        let screenFrame = screen.visibleFrame
        let origin = NSPoint(
            x: screenFrame.maxX - frame.width - margin,
            y: screenFrame.maxY - frame.height - margin
        )
        setFrameOrigin(origin)
    }

    func toggle() {
        if isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                animator().alphaValue = 0
            } completionHandler: {
                self.orderOut(nil)
            }
        } else {
            alphaValue = 0
            makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                animator().alphaValue = 1
            }
        }
    }

    override func cancelOperation(_ sender: Any?) {
        toggle()
    }

    // MARK: - Keyboard shortcuts

    /// Handles the panel's interaction-layer shortcuts (⌘C, ⇧⌘C, Space,
    /// Return, ⇧⌘M, ⌫, arrows, Esc) via a `keyDown` override rather than a
    /// separate `NSEvent` local monitor, since the panel is already the
    /// natural place these unhandled key events land (see `cancelOperation`
    /// above, which relies on the same responder-chain forwarding).
    override func keyDown(with event: NSEvent) {
        if let panelActions, !isEditingText, handle(event, actions: panelActions) {
            return
        }
        super.keyDown(with: event)
    }

    /// True while the search field, composer, or an inline note edit has
    /// focus (all of these are backed by an `NSTextView` field editor),
    /// meaning shortcuts must not fire so normal typing/editing works.
    private var isEditingText: Bool {
        firstResponder is NSTextView
    }

    /// Returns `true` if the event was handled as a panel shortcut.
    private func handle(_ event: NSEvent, actions: PanelActions) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])

        switch event.keyCode {
        case 125: // Down arrow
            actions.selection.moveSelection(direction: 1, extend: modifiers == [.shift])
            return true
        case 126: // Up arrow
            actions.selection.moveSelection(direction: -1, extend: modifiers == [.shift])
            return true
        case 36: // Return
            actions.startEditingIfSingleSelected()
            return true
        case 49: // Space
            actions.toggleDone()
            return true
        case 51, 117: // Delete / Forward Delete
            actions.delete()
            return true
        case 53: // Escape
            if !actions.selection.selectedIDs.isEmpty {
                actions.selection.clear()
            } else {
                toggle()
            }
            return true
        default:
            break
        }

        let characters = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == [.command], characters == "c" {
            actions.copy()
            return true
        }
        if modifiers == [.command, .shift] {
            if characters == "c" {
                actions.copyAsList()
                return true
            }
            if characters == "m" {
                actions.merge()
                return true
            }
        }

        return false
    }
}

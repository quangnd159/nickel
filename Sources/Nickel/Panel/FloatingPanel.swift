import AppKit
import SwiftUI

final class FloatingPanel: NSPanel, NSWindowDelegate {
    private let selectionModel = SelectionModel()
    private var panelActions: PanelActions?

    /// Bumped on every `toggle()` call; an in-flight show/hide animation
    /// checks this in its completion handler and no-ops if it's stale, so a
    /// rapid double-shift can never have an old hide land after a newer show
    /// (or vice versa) — whichever call is most recent always wins.
    private var toggleGeneration = 0

    /// Suppresses frame persistence while `toggle()`'s own show/hide slide
    /// animation is moving the window, so the animation's intermediate
    /// frames never get written to `UserDefaults` as the "real" frame.
    private var isAnimatingToggle = false

    private static let savedFrameDefaultsKey = "NickelPanelFrame"
    private static let toggleSlideOffset: CGFloat = 8
    private static let toggleAnimationDuration: TimeInterval = 0.18

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
        delegate = self

        let actions = PanelActions(store: store, selection: selectionModel)
        panelActions = actions

        contentView = NSHostingView(
            rootView: PanelView()
                .environmentObject(store)
                .environmentObject(selectionModel)
                .environmentObject(actions)
        )

        restoreOrPositionFrame()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    override var canBecomeKey: Bool { true }

    // MARK: - Positioning & frame persistence

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

    /// Restores the panel's last-saved frame (clamped to a currently
    /// connected screen), falling back to the default top-right position if
    /// nothing was saved or the saved frame is no longer on any screen.
    private func restoreOrPositionFrame() {
        if let saved = Self.loadSavedFrame(), let clamped = clampToVisibleScreen(saved) {
            setFrame(clamped, display: false)
        } else {
            positionNearTopRight()
        }
    }

    private static func loadSavedFrame() -> NSRect? {
        guard let string = UserDefaults.standard.string(forKey: savedFrameDefaultsKey) else { return nil }
        let rect = NSRectFromString(string)
        guard rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    /// Clamps `rect` to whichever connected screen it currently overlaps.
    /// Returns `nil` if `rect` is entirely offscreen (e.g. its screen was
    /// disconnected), signaling the caller should fall back to the default.
    private func clampToVisibleScreen(_ rect: NSRect) -> NSRect? {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(rect) }) else {
            return nil
        }
        let visible = screen.visibleFrame
        var clamped = rect
        clamped.size.width = min(clamped.size.width, visible.width)
        clamped.size.height = min(clamped.size.height, visible.height)
        clamped.origin.x = min(max(clamped.origin.x, visible.minX), visible.maxX - clamped.width)
        clamped.origin.y = min(max(clamped.origin.y, visible.minY), visible.maxY - clamped.height)
        return clamped
    }

    private func saveFrame() {
        guard !isAnimatingToggle else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.savedFrameDefaultsKey)
    }

    @objc private func screenParametersChanged() {
        guard !isAnimatingToggle else { return }
        if let clamped = clampToVisibleScreen(frame) {
            if clamped != frame {
                setFrame(clamped, display: true)
            }
        } else {
            positionNearTopRight()
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveFrame()
    }

    // MARK: - Show / hide

    /// Toggles panel visibility with a subtle slide-and-fade. Uses a
    /// generation counter so that whichever of show/hide was requested most
    /// recently always wins: if a hide's fade-out is still animating when a
    /// new show comes in (rapid double-shift), the hide's completion handler
    /// detects it's stale and skips `orderOut`, so the panel doesn't get
    /// hidden right after being shown again.
    func toggle() {
        toggleGeneration += 1
        let generation = toggleGeneration

        if isVisible {
            animateHide(generation: generation)
        } else {
            animateShow(generation: generation)
        }
    }

    private func animateShow(generation: Int) {
        isAnimatingToggle = true
        let targetFrame = frame
        var startFrame = targetFrame
        startFrame.origin.x += Self.toggleSlideOffset
        setFrame(startFrame, display: false)
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        // AppKit auto-assigns first responder to the first key-view (the
        // search field) when the panel becomes key. Clear it so the panel
        // opens with no text focus and note shortcuts (⌘C, Space, etc.) work
        // immediately; clicking the search field still focuses it normally.
        makeFirstResponder(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.toggleAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self] in
            guard let self, generation == self.toggleGeneration else { return }
            self.isAnimatingToggle = false
        }
    }

    private func animateHide(generation: Int) {
        isAnimatingToggle = true
        let restingFrame = frame
        var endFrame = restingFrame
        endFrame.origin.x += Self.toggleSlideOffset

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.toggleAnimationDuration * 0.8
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
            animator().setFrame(endFrame, display: true)
        } completionHandler: { [weak self] in
            guard let self, generation == self.toggleGeneration else { return }
            self.orderOut(nil)
            // Restore the resting (pre-slide) frame now that the window is
            // hidden, so the next show animates from the right place.
            self.setFrame(restingFrame, display: false)
            self.isAnimatingToggle = false
        }
    }

    override func cancelOperation(_ sender: Any?) {
        toggle()
    }

    /// Backs the Edit menu's Select All (⌘A) when the panel itself is first
    /// responder (i.e. no text field has focus, in which case its field
    /// editor handles ⌘A as "select all text" instead — the menu item
    /// targets whatever's first responder, so no key-equivalent routing is
    /// needed here).
    override func selectAll(_ sender: Any?) {
        selectionModel.selectAllNotes()
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
    /// meaning shortcuts must not fire so normal typing/editing works. Esc
    /// while the search field has text is instead handled by `SearchField`
    /// itself (clear vs. blur), since it needs to see the current text.
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
        if modifiers == [.command], characters == "f" {
            NotificationCenter.default.post(name: .nickelFocusSearch, object: nil)
            return true
        }
        if modifiers == [.command], characters == "n" {
            NotificationCenter.default.post(name: .nickelFocusComposer, object: nil)
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

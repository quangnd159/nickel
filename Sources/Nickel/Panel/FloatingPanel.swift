import AppKit
import SwiftUI

final class FloatingPanel: NSPanel, NSWindowDelegate {
    // Implicitly-unwrapped: `SelectionModel` needs the store, which isn't
    // available until inside the convenience init below (after the
    // required `self.init(contentRect:...)` call), so it can't be a
    // default-valued `let` the way the old parameterless `SelectionModel()`
    // was. Set exactly once, immediately after `self.init`, before anything
    // else in the initializer touches it.
    private var selectionModel: SelectionModel!
    private var panelActions: PanelActions?

    /// Read by `ComposerFocusTests`, which drives a real panel to check that
    /// the composer's focus flag follows first responder and key state.
    var selectionModelForTesting: SelectionModel { selectionModel }

    /// Read by `AppDelegate.validateMenuItem` to enable/disable the View
    /// menu's "Move to Section…" item based on the current selection.
    var currentSelectionModel: SelectionModel { selectionModel }

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
            // Deliberately NOT `.nonactivatingPanel`: that flag opts the
            // window out of native click-to-activate, and since macOS 14's
            // cooperative activation an app can no longer force-activate
            // itself to compensate (`activate()` is only a request, honored
            // when the frontmost app yields or the user clicks one of our
            // windows). A normal panel gets activation — and with it the
            // menu bar — through the system's own path.
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        level = PanelSettings.keepPanelOnTop ? .floating : .normal
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        delegate = self

        selectionModel = SelectionModel(store: store)
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keepOnTopSettingChanged),
            name: PanelSettings.keepOnTopDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(closeRequested),
            name: .nickelClosePanel,
            object: nil
        )
    }

    @objc private func keepOnTopSettingChanged() {
        level = PanelSettings.keepPanelOnTop ? .floating : .normal
    }

    /// Posted by the ⋯ menu's "Close" item: hides the panel via the same
    /// animated path as ⌘W and the right-Shift toggle, rather than a plain
    /// `orderOut`.
    @objc private func closeRequested() {
        if isVisible {
            toggle()
        }
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

    /// A field editor that refuses every drag. `NSTextView` natively claims
    /// drags of files it can read as text (a `.txt` from Finder), which
    /// swallowed those drags before the composer card's SwiftUI drop region
    /// could stage the file as an attachment — while PDFs/images, which the
    /// text system refuses, fell through and attached fine. Refusing all
    /// drags at the field editor makes every file type take the same
    /// fall-through path to the drop region. (Drops of plain *text content*
    /// still work: the drop region itself inserts text into the composer.)
    private final class DragRejectingFieldEditor: NSTextView {
        override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [] }
    }

    private lazy var dragRejectingFieldEditor: DragRejectingFieldEditor = {
        let editor = DragRejectingFieldEditor()
        editor.isFieldEditor = true
        return editor
    }()

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard client is GrowingTextField else { return nil }
        return dragRejectingFieldEditor
    }

    // MARK: - Composer focus

    /// Every first-responder change in this window funnels through here, so
    /// this is where `SelectionModel.isComposerFocused` is kept true — the
    /// composer's "#" suggestion popup and its focus ring both follow it.
    ///
    /// `nil` — "give up text focus", which the background click, a click on a
    /// row, Escape in an empty search field and the end of an inline edit all
    /// ask for — hands focus to the note list instead of leaving it on the
    /// window. The list is a real `NSTableView` now, and it has to be first
    /// responder for its own arrow-key navigation to run at all. Keeping that
    /// redirect here, rather than at each call site, keeps this window the
    /// single focus authority it already was.
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let didChange = super.makeFirstResponder(responder ?? noteListTable())
        syncComposerFocus()
        return didChange
    }

    /// The note list's table view, wherever it currently sits in the
    /// SwiftUI-hosted hierarchy (the live list and the Logbook each have their
    /// own, and only one is on screen at a time).
    private func noteListTable() -> NSTableView? {
        guard let contentView else { return nil }
        var queue: [NSView] = [contentView]
        while let view = queue.first {
            queue.removeFirst()
            if let table = view as? NoteListTableView { return table }
            queue += view.subviews
        }
        return nil
    }

    /// Key state as AppKit reports it through these two overrides, rather than
    /// read back from `isKeyWindow` at sync time: losing key means the
    /// composer stops being the focused control even though its field editor
    /// is still first responder (AppKit doesn't end editing here, so no
    /// field-level callback fires — these overrides are the only signal), and
    /// that must not depend on exactly when AppKit flips its own flag.
    private var isPanelKey = false

    override func becomeKey() {
        super.becomeKey()
        isPanelKey = true
        syncComposerFocus()
    }

    override func resignKey() {
        super.resignKey()
        isPanelKey = false
        syncComposerFocus()
    }

    /// The composer is focused when this window is key and its first
    /// responder is the composer's field editor. Identity against
    /// `dragRejectingFieldEditor` is exact: `windowWillReturnFieldEditor`
    /// hands it out only to `GrowingTextField`, which only `ComposerField`
    /// uses — the search field, header rename, and palette query all get the
    /// window's standard field editor instead.
    private func syncComposerFocus() {
        guard isPanelKey || isKeyWindow, let editor = firstResponder as? NSTextView else {
            selectionModel?.setComposerFocused(false)
            return
        }
        selectionModel?.setComposerFocused(editor === dragRejectingFieldEditor)
    }

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveFrame()
    }

    // MARK: - Show / hide

    /// Three-state cycle, matching iTerm2's hotkey window / Quake-style
    /// terminals / Fantastical's mini window: hidden → show + focus; visible
    /// but not focused (user clicked into another app, panel stayed on
    /// screen) → bring to front and focus, without hiding; visible and
    /// focused → hide. Since the panel isn't `.nonactivatingPanel`, "visible
    /// but unfocused" in practice means Nickel isn't the active app, so
    /// `isKeyWindow && NSApp.isActive` is the frontmost-and-focused check.
    ///
    /// Uses a generation counter so that whichever call was requested most
    /// recently always wins: if a hide's fade-out is still animating when a
    /// new show/refocus comes in (rapid double-shift), the hide's completion
    /// handler detects it's stale and skips `orderOut`, so the panel doesn't
    /// get hidden right after being shown/refocused again.
    func toggle() {
        toggleGeneration += 1
        let generation = toggleGeneration

        if isVisible {
            if isKeyWindow && NSApp.isActive {
                animateHide(generation: generation)
            } else if isAnimatingToggle {
                // Mid-animation (a hide fading out, or a show still settling):
                // the frame/alpha aren't at rest, so route through the show
                // animation, which resets both; the generation check above
                // already makes any stale in-flight hide a no-op.
                animateShow(generation: generation)
            } else {
                // At rest on screen, just not focused: bring forward without
                // replaying the slide/fade (it's already in place) and without
                // resetting first responder (AppKit restores it on its own).
                activateForSummon()
                makeKeyAndOrderFront(nil)
            }
        } else {
            animateShow(generation: generation)
        }
    }

    private func animateShow(generation: Int) {
        isAnimatingToggle = true
        // If a previous hide left the app hidden (see `animateHide`'s
        // yield-focus step), bring it back so its windows can order front
        // again.
        if NSApp.isHidden {
            NSApp.unhideWithoutActivation()
        }
        // Without `.nonactivatingPanel`, the panel only receives keyboard
        // input while Nickel is the active app, so a hotkey summon has to
        // request activation.
        activateForSummon()
        let targetFrame = frame
        var startFrame = targetFrame
        startFrame.origin.x += Self.toggleSlideOffset
        setFrame(startFrame, display: false)
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        // AppKit auto-assigns first responder to the first key-view (the
        // search field) when the panel becomes key. Clear it so the panel
        // opens with the note list focused instead: note shortcuts (⌘C,
        // Space, arrows) work immediately, and no text field has focus.
        // Clicking the search field still focuses it normally. Laid out first
        // so the list's table view exists to receive focus on the very first
        // show (`NoteListCoordinator` claims it as a backstop if not).
        contentView?.layoutSubtreeIfNeeded()
        _ = makeFirstResponder(nil)

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
            self.yieldFocusIfNeeded()
        }
    }

    /// With the Dock icon on, a panel click can `NSApp.activate` Nickel (see
    /// `sendEvent`). If the panel is then dismissed while Nickel is still
    /// active and no other Nickel window (Settings, About) is up, activation
    /// would otherwise strand Nickel as the active app with no windows and a
    /// stale menu bar — `NSApp.hide(nil)` is the standard trick to hand
    /// focus back to whatever was frontmost before. `animateShow` undoes
    /// this with `unhideWithoutActivation()` the next time the panel opens.
    private func yieldFocusIfNeeded() {
        guard NSApp.isActive else { return }
        // "Other windows" means real, titled ones (Settings, the About
        // panel — itself an `NSPanel`, so a class check would miss it), not
        // chrome like the status item's window or the capture HUD, which are
        // borderless and always around.
        let otherWindowVisible = NSApp.windows.contains {
            $0.isVisible && $0 !== self && $0.styleMask.contains(.titled)
        }
        guard !otherWindowVisible else { return }
        NSApp.hide(nil)
    }

    override func cancelOperation(_ sender: Any?) {
        toggle()
    }

    /// Handles ⌘K (section switcher), ⌃⌘M (move selection to section), ⌘/
    /// (keyboard shortcuts), ⌘F (focus search), ⌘N (focus composer), and the
    /// attachment-paste ⌘V case by
    /// overriding `performKeyEquivalent` rather than folding them into
    /// `keyDown`'s `handle(_:actions:)`: command key-equivalents are routed
    /// to the focused view first (the search field, composer, or an inline
    /// edit's field editor), which would otherwise swallow them as normal
    /// typing. Overriding here, ahead of `super`'s content-view dispatch,
    /// means all of these always fire regardless of what has focus — e.g.
    /// ⌘F/⌘N work to jump between fields even while another field already
    /// has focus, not just when the panel background does.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let characters = event.charactersIgnoringModifiers?.lowercased()

        if modifiers == [.command], characters == "k" {
            NotificationCenter.default.post(name: .nickelToggleSectionSwitcher, object: nil)
            return true
        }
        if modifiers == [.command, .control], characters == "m" {
            NotificationCenter.default.post(name: .nickelToggleMoveToSection, object: nil)
            return true
        }
        if modifiers == [.command], characters == "/" {
            NotificationCenter.default.post(name: .nickelToggleShortcuts, object: nil)
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
        if modifiers == [.command], characters == "w" {
            if isVisible { toggle() }
            return true
        }
        if modifiers == [.command], characters == "," {
            SettingsWindowController.shared.show()
            return true
        }
        // ⌘⇧] / ⌘⇧[ cycle through Show All + each section in order. Matched
        // loosely: with Shift held, `charactersIgnoringModifiers` (which
        // honors Shift, unlike Command) can deliver either the bracket itself
        // or its shifted form ("}"/"{"), and observed behavior has varied by
        // keyboard layout, so the keyCode (30 = ']', 33 = '[' on ANSI) is
        // checked as a robust fallback alongside the characters.
        if modifiers == [.command, .shift],
           characters == "]" || characters == "}" || event.keyCode == 30 {
            cycleSection(direction: 1)
            return true
        }
        if modifiers == [.command, .shift],
           characters == "[" || characters == "{" || event.keyCode == 33 {
            cycleSection(direction: -1)
            return true
        }
        // ⇧⌘R renames the focused section, mirroring the header's
        // double-click/context-menu rename. Swallowed even with no section
        // focused (or an overlay already up) so it never falls through to
        // type into a field.
        if modifiers == [.command, .shift], characters == "r" {
            if let section = panelActions?.store.activeSection, selectionModel.presentedOverlay == nil {
                selectionModel.beginRenamingSection(section)
            }
            return true
        }

        // ⌘V when the pasteboard has attachable content: redirect to staging
        // attachments in the composer instead of a normal text paste. This
        // intercepts ahead of the Edit menu's Paste (which would otherwise
        // route `paste:` to a focused field editor), which is exactly what we
        // want for files: Finder's copy puts the *filename* on the pasteboard
        // as plain text alongside the file URLs, so a plain-text paste of a
        // copied file would insert its name rather than attach it — the file
        // URLs must win whenever they're present. Raw images (screenshots)
        // are attached only when there's no plain text, so copied rich text
        // that happens to carry an image rendition still pastes as text. No
        // focus check is needed: pasting files with, say, the search field
        // focused is meaningless anyway, and staging them in the composer is
        // still the right outcome.
        if modifiers == [.command], characters == "v", pasteboardHasAttachableContent() {
            NotificationCenter.default.post(name: .nickelComposerPaste, object: nil)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    /// Activates Nickel for a hotkey summon. Under macOS 14 cooperative
    /// activation a bare `NSApp.activate()` is routinely declined when
    /// another app is frontmost (a global event tap isn't user intent the
    /// system recognizes), which left the summoned panel visible but not
    /// key. `activate(from:options:)` is the documented handoff for exactly
    /// this: the target names the frontmost app as the one yielding to it.
    /// The bare `activate()` remains as a fallback if that's declined.
    private func activateForSummon() {
        guard !NSApp.isActive else { return }
        if let front = NSWorkspace.shared.frontmostApplication,
           front != .current,
           NSRunningApplication.current.activate(from: front, options: []) {
            return
        }
        NSApp.activate()
    }

    /// Steps the active section forward (`direction: 1`) or backward
    /// (`direction: -1`). The cycle itself lives on `NoteStore` so the panel
    /// and the View menu's Next/Previous Section items share one
    /// implementation.
    private func cycleSection(direction: Int) {
        panelActions?.store.cycleActiveSection(direction: direction)
    }

    /// True when the general pasteboard carries file URLs (regardless of any
    /// accompanying text — see `performKeyEquivalent`'s ⌘V comment), or image
    /// data with no plain text.
    private func pasteboardHasAttachableContent() -> Bool {
        let pasteboard = NSPasteboard.general

        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return true
        }

        let hasText = pasteboard.types?.contains(.string) ?? false
        guard !hasText else { return false }
        return pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
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
    /// Esc while an overlay is presented always closes the overlay, no
    /// matter what has focus. Intercepted in `sendEvent` (not `keyDown`)
    /// because a focused field editor otherwise consumes Esc via its
    /// `cancelOperation` before the event ever reaches the window's
    /// `keyDown` — e.g. opening the ⌘/ shortcuts card while the composer has
    /// focus would take two Escapes (one blurring the composer, one closing
    /// the card). This also covers the section switcher's own field, whose
    /// `cancelOperation` intercept becomes a never-reached fallback.
    ///
    /// Also activates Nickel on a deliberate mouse click into the panel,
    /// when the Dock icon setting is on. The panel stays a
    /// `.nonactivatingPanel` so double-shift show and typing never steal
    /// activation from the frontmost app (that's the whole point of the
    /// capture flow), but a click should behave like clicking any other
    /// app's window — otherwise Nickel would have a menu bar and Dock icon
    /// that never actually go frontmost. Checked here rather than in
    /// `mouseDown`, since clicks landing on subviews (buttons, fields) are
    /// dispatched straight to those views and never reach the window's own
    /// `mouseDown`.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, selectionModel.presentedOverlay != nil {
            // Same animation the overlay opened with (`PanelView.toggleOverlay`),
            // so Esc and ⌘K close it identically.
            withAnimation(.panelOverlay) {
                selectionModel.presentedOverlay = nil
            }
            return
        }
        super.sendEvent(event)
    }

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

    /// Returns `true` if the event was handled as a panel shortcut. Matching
    /// itself lives in the `PanelShortcuts` table (see that file for why);
    /// this switch is only the dispatch, plus the one event-context decision
    /// the table deliberately leaves to the panel: Escape's
    /// clear-selection-else-toggle branch.
    private func handle(_ event: NSEvent, actions: PanelActions) -> Bool {
        guard let command = PanelShortcuts.command(for: event) else { return false }

        switch command {
        case .moveDown, .moveUp:
            // The table's own navigation, handled before the event ever
            // reaches the window — see `NoteListTableView.keyDown`. Reaching
            // here means the list doesn't have focus, in which case an arrow
            // key has nothing to move.
            return false
        case .edit:
            actions.startEditingIfSingleSelected()
        case .editInNewWindow:
            actions.editInNewWindow()
        case .toggleDone:
            actions.toggleDone()
        case .delete:
            actions.delete()
        case .moveToLogbook:
            actions.moveToLogbook()
        case .escape:
            if actions.selection.isShowingLogbook, actions.selection.selectedIDs.isEmpty {
                // Esc peels one layer at a time everywhere else in the panel,
                // so in the Logbook it clears the selection first (the branch
                // below) and only then backs out of the view itself.
                actions.selection.setShowingLogbook(false)
            } else if !actions.selection.selectedIDs.isEmpty {
                actions.selection.clear()
            } else {
                toggle()
            }
        case .copy:
            actions.copy()
        case .toggleExpanded:
            actions.toggleExpanded()
        case .copyAsList:
            actions.copyAsList()
        case .merge:
            actions.merge()
        }
        return true
    }
}

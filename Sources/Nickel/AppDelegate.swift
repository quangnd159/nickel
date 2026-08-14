import AppKit

/// The five menu items shared by the app menu and the status-item menu —
/// see `AppDelegate.appMenuCoreItems()`.
private struct AppMenuCoreItems {
    let about: NSMenuItem
    let checkForUpdates: NSMenuItem
    let revealInFinder: NSMenuItem
    let settings: NSMenuItem
    let quit: NSMenuItem
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem?
    private var panel: FloatingPanel?
    private var trustPollTimer: Timer?
    private var wasTrusted = Permissions.isTrusted

    private let noteStore = NoteStore()
    private lazy var noteEditorWindows = NoteEditorWindowManager(store: noteStore)
    private var isCapturing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()

        let panel = FloatingPanel(store: noteStore)
        self.panel = panel

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = StatusItemIcon.make()
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Nickel"
            button.setAccessibilityLabel("Nickel")
        }
        // Intentionally not `item.menu = ...`: setting `menu` directly makes
        // *every* click (left or right) show the menu instead of reaching
        // `statusItemClicked`. The menu is instead assigned on demand for a
        // right-click only, in `statusItemClicked`.
        item.isVisible = PanelSettings.showMenuBarIcon
        statusItem = item

        NotificationCenter.default.addObserver(
            forName: PanelSettings.showMenuBarIconDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.statusItem?.isVisible = PanelSettings.showMenuBarIcon
        }

        NotificationCenter.default.addObserver(
            forName: .nickelEditNoteInNewWindow,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let noteID = notification.object as? UUID else { return }
            self?.noteEditorWindows.open(noteID: noteID)
        }

        HotkeyMonitor.shared.onDoubleTap = { [weak self] key in self?.handleDoubleTap(key) }
        HotkeyMonitor.shared.onCommandV = { [weak self] event in self?.handleCommandV(event) }
        startHotkeyMonitorOrPromptForAccess()

        panel.toggle()
    }

    private func startHotkeyMonitorOrPromptForAccess() {
        if Permissions.isTrusted {
            HotkeyMonitor.shared.start()
        } else {
            // Triggers the native "Nickel.app would like to control this
            // computer" system dialog, which also registers Nickel in the
            // Accessibility list.
            Permissions.requestIfNeeded()
        }

        // Accessibility trust can change in either direction at any time —
        // the user can revoke it (or re-grant it) in System Settings while
        // Nickel keeps running — and macOS has no public notification for
        // that change, only the polling `AXIsProcessTrusted` check wrapped
        // by `Permissions.isTrusted`. So this timer never self-invalidates:
        // it runs for the app's lifetime, watching for trust to flip in
        // either direction and starting/stopping the hotkey monitor to
        // match.
        trustPollTimer?.invalidate()
        trustPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let isTrusted = Permissions.isTrusted
            guard let action = Self.trustTransitionAction(was: self.wasTrusted, now: isTrusted) else { return }
            self.wasTrusted = isTrusted
            switch action {
            case .start:
                HotkeyMonitor.shared.start()
            case .stop:
                HotkeyMonitor.shared.stop()
            }
        }
        trustPollTimer?.tolerance = 0.5
    }

    enum TrustAction: Equatable {
        case start
        case stop
    }

    /// Pure decision for the trust-watcher timer: given the trust state at
    /// the previous tick and now, what should happen to the hotkey monitor?
    /// `nil` means no transition occurred.
    static func trustTransitionAction(was: Bool, now: Bool) -> TrustAction? {
        guard now != was else { return nil }
        return now ? .start : .stop
    }

    /// Routes by the user's configured keys, read live so a Settings change
    /// applies immediately without restart. A key that matches neither
    /// setting (unreachable via the UI, since they're always distinct) is
    /// ignored rather than defaulting to either action.
    private func handleDoubleTap(_ key: ModifierKey) {
        switch key {
        case PanelSettings.panelToggleKey:
            // Toggling here also dismisses the panel while it's key, which
            // commits any in-progress edit (renaming a list, composing) via
            // the existing focus-loss paths.
            panel?.toggle()
        case PanelSettings.captureKey:
            captureSelectedText()
        default:
            break
        }
    }

    /// Feeds every ⌘V keyDown `HotkeyMonitor` observes to
    /// `SequentialPasteCoordinator`, translating the raw `NSEvent` into the
    /// three booleans its testable `handleCommandV` needs: whether this is
    /// our own synthetic paste looping back (via the `eventSourceUserData`
    /// marker), a key-repeat, or typed while Nickel itself is frontmost
    /// (e.g. into the search field, which isn't the "paste into another
    /// app" this coordinator exists for).
    private func handleCommandV(_ event: NSEvent) {
        let isSynthetic = event.cgEvent?.getIntegerValueField(.eventSourceUserData)
            == SequentialPasteCoordinator.syntheticEventUserData
        let frontmostAppIsNickel = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        SequentialPasteCoordinator.shared.handleCommandV(
            isSynthetic: isSynthetic,
            isRepeat: event.isARepeat,
            frontmostAppIsNickel: frontmostAppIsNickel
        )
    }

    private func captureSelectedText() {
        guard !isCapturing else { return }
        isCapturing = true

        let appName = CaptureEngine.frontmostAppName
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = CaptureEngine.captureSelectedText()
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.isCapturing = false }

                if let text, !text.isEmpty {
                    self.noteStore.add(text: text, sourceApp: appName, isCapture: true)
                    CaptureHUD.show()
                } else {
                    CaptureHUD.show(message: "No text selected", symbolName: "exclamationmark.circle.fill")
                }
            }
        }
    }

    /// The full, Copper-parity main menu, shown in the menu bar whenever
    /// Nickel is the active app. AppKit also routes key equivalents (⌘Q,
    /// ⌘C/V/X/A, ⌘Z) through it, which is what keeps those shortcuts
    /// working in the search field, composer, and inline editors.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let coreItems = appMenuCoreItems()

        appMenu.addItem(coreItems.about)
        appMenu.addItem(coreItems.checkForUpdates)

        appMenu.addItem(.separator())

        appMenu.addItem(coreItems.revealInFinder)

        appMenu.addItem(.separator())

        appMenu.addItem(coreItems.settings)

        appMenu.addItem(.separator())

        let servicesMenu = NSMenu()
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu

        appMenu.addItem(.separator())

        let hideItem = NSMenuItem(
            title: "Hide Nickel",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)

        appMenu.addItem(
            NSMenuItem(
                title: "Show All",
                action: #selector(NSApplication.unhideAllApplications(_:)),
                keyEquivalent: ""
            )
        )

        appMenu.addItem(.separator())

        appMenu.addItem(coreItems.quit)

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // A "File" menu with New Note and Close: the standard first menu
        // after the app menu, even though Nickel has no document model —
        // both items act on the one panel, same as every View item below.
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(windowMenuItem(for: .newNote, action: #selector(newNote)))
        fileMenu.addItem(.separator())
        fileMenu.addItem(windowMenuItem(for: .closePanel, action: #selector(closePanel)))
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        )
        editMenu.addItem(
            withTitle: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "z"
        ).keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        // `NSText.copy(_:)` resolves to the plain `copy:` selector, which
        // `NoteListTableView` also implements — so with the note list (not a
        // field editor) focused, this item acts on the note selection.
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        // No key equivalent: ⌫ already deletes via the panel/field's own key
        // handling, so this exists for discoverability and menu-driven use
        // (e.g. VoiceOver), not as the primary way to delete. Like Copy
        // above, `NSText.delete(_:)` resolves to `delete:`, which
        // `NoteListTableView` also implements, so this acts on the note
        // selection when the list has focus.
        editMenu.addItem(NSMenuItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: ""))
        editMenu.addItem(.separator())
        editMenu.addItem(
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        )
        editMenu.addItem(.separator())
        editMenu.addItem(windowMenuItem(for: .findFocus, action: #selector(focusSearch)))
        editMenu.addItem(.separator())
        // No target: routed through the responder chain to the system's own
        // handler, which supplies the fn/🌐 key equivalent itself.
        editMenu.addItem(
            NSMenuItem(
                title: "Emoji & Symbols",
                action: #selector(NSApplication.orderFrontCharacterPalette(_:)),
                keyEquivalent: ""
            )
        )
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // A "View" menu for section navigation: each item first shows the
        // panel if it's hidden, so ⌘K/⌃⌘M/⇧⌘]/⇧⌘[/⌘/ work from the menu even
        // before the panel has ever been summoned. While the panel is key,
        // its own `performKeyEquivalent` intercepts these key equivalents
        // ahead of the menu, so there's no double-handling.
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")

        viewMenu.addItem(windowMenuItem(for: .sectionSwitcher, action: #selector(switchSection)))
        viewMenu.addItem(windowMenuItem(for: .moveToSection, action: #selector(moveToSection)))

        viewMenu.addItem(.separator())

        viewMenu.addItem(windowMenuItem(for: .nextSection, action: #selector(nextSection)))
        viewMenu.addItem(windowMenuItem(for: .previousSection, action: #selector(previousSection)))

        viewMenu.addItem(.separator())

        viewMenu.addItem(windowMenuItem(for: .shortcutsCard, action: #selector(showKeyboardShortcuts)))

        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // A "Window" menu with the standard Minimize/Zoom/Close/Bring All to
        // Front items. Close is bound to ⌘W via `performClose:`, so ⌘W closes
        // the Settings window (a plain titled `NSWindow`, unlike
        // `FloatingPanel`, which handles ⌘W itself in its own
        // `performKeyEquivalent` override and so never reaches here while
        // it's key).
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        )
        windowMenu.addItem(
            NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        )
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        )
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        )
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        // A "Help" menu with a single link out to the project's GitHub page.
        // Assigning it to `NSApp.helpMenu` lets macOS append its native
        // search field above the item automatically.
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        let helpItem = NSMenuItem(title: "Nickel Help", action: #selector(showHelp), keyEquivalent: "?")
        helpItem.target = self
        helpMenu.addItem(helpItem)
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    /// Shared by the View menu's Switch Section / Next Section / Previous
    /// Section / Keyboard Shortcuts items: the panel has to be visible before
    /// any of these mean anything, since they all act on (or are shown atop)
    /// its content.
    private func showPanelIfHidden() {
        if let panel, !panel.isVisible {
            panel.toggle()
        }
    }

    /// Builds a menu item from `WindowShortcuts`' table entry for `command`
    /// — the single source of truth its title and key equivalent come from
    /// (see `PanelShortcuts.swift`'s `WindowShortcut`).
    private func windowMenuItem(for command: WindowCommand, action: Selector) -> NSMenuItem {
        let shortcut = WindowShortcuts.shortcut(for: command)
        let item = NSMenuItem(title: shortcut.menuTitle, action: action, keyEquivalent: shortcut.menuKeyEquivalent.key)
        item.keyEquivalentModifierMask = shortcut.menuKeyEquivalent.modifiers
        item.target = self
        return item
    }

    @objc private func newNote() {
        showPanelIfHidden()
        NotificationCenter.default.post(name: .nickelFocusComposer, object: nil)
    }

    /// The File menu's Close: mirrors the panel's own ⌘W handling (a no-op
    /// with nothing visible to close), rather than `showPanelIfHidden()` +
    /// close, which would show the panel only to immediately hide it again.
    @objc private func closePanel() {
        if let panel, panel.isVisible {
            panel.toggle()
        }
    }

    @objc private func focusSearch() {
        showPanelIfHidden()
        NotificationCenter.default.post(name: .nickelFocusSearch, object: nil)
    }

    @objc private func switchSection() {
        showPanelIfHidden()
        panel?.currentSelectionModel.toggleSectionSwitcher()
    }

    @objc private func moveToSection() {
        showPanelIfHidden()
        panel?.currentSelectionModel.toggleMoveToSection()
    }

    @objc private func nextSection() {
        showPanelIfHidden()
        noteStore.cycleActiveSection(direction: 1)
    }

    @objc private func previousSection() {
        showPanelIfHidden()
        noteStore.cycleActiveSection(direction: -1)
    }

    @objc private func showKeyboardShortcuts() {
        showPanelIfHidden()
        panel?.currentSelectionModel.toggleOverlay(.shortcuts)
    }

    @objc private func showHelp() {
        NSWorkspace.shared.open(URL(string: "https://github.com/quangnd159/nickel")!)
    }

    /// Disables "Move to Section…" when there's nothing to move (matches
    /// `SelectionModel.toggleMoveToSection`'s own no-op guard); every other
    /// menu item stays enabled, so this returns `true` for anything else.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(moveToSection) else { return true }
        guard let selection = panel?.currentSelectionModel else { return false }
        return !selection.isShowingLogbook && !selection.selectedIDs.isEmpty
    }

    /// The status item's right-click menu: a compact mirror of the app menu
    /// for reaching Nickel without activating it (the real menu bar only
    /// shows while Nickel is the active app).
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let coreItems = appMenuCoreItems()

        menu.addItem(coreItems.about)
        menu.addItem(coreItems.checkForUpdates)

        menu.addItem(.separator())

        menu.addItem(coreItems.revealInFinder)
        menu.addItem(coreItems.settings)

        menu.addItem(.separator())

        let toggleItem = NSMenuItem(
            title: "Toggle Panel",
            action: #selector(togglePanel),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        if !Permissions.isTrusted {
            let grantItem = NSMenuItem(
                title: "Grant Accessibility Access…",
                action: #selector(grantAccessibilityAccess),
                keyEquivalent: ""
            )
            grantItem.target = self
            menu.addItem(grantItem)
        }

        menu.addItem(.separator())

        menu.addItem(coreItems.quit)

        return menu
    }

    /// About / Check for Updates… / Reveal Notes in Finder / Settings… /
    /// Quit — the five items both `setupMainMenu`'s app menu and `makeMenu`'s
    /// status-item menu show, kept in one place so their titles and key
    /// equivalents (Settings' ⌘, in particular) can't drift between the two.
    /// Builds fresh `NSMenuItem`s on every call: an item can't sit in two
    /// menus at once.
    private func appMenuCoreItems() -> AppMenuCoreItems {
        let about = NSMenuItem(title: "About Nickel", action: #selector(showAbout), keyEquivalent: "")
        about.target = self

        let checkForUpdates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        checkForUpdates.target = self

        let revealInFinder = NSMenuItem(
            title: "Reveal Notes in Finder",
            action: #selector(revealNotesInFinder),
            keyEquivalent: ""
        )
        revealInFinder.target = self

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self

        let quit = NSMenuItem(title: "Quit Nickel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        return AppMenuCoreItems(
            about: about,
            checkForUpdates: checkForUpdates,
            revealInFinder: revealInFinder,
            settings: settings,
            quit: quit
        )
    }

    @objc private func togglePanel() {
        panel?.toggle()
    }

    @objc private func grantAccessibilityAccess() {
        Permissions.openAccessibilitySettings()
    }

    @objc private func revealNotesInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([noteStore.fileURL])
    }

    @objc private func showSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func checkForUpdates() {
        UpdateChecker.check()
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    /// Left click toggles the panel directly; right click shows the overflow
    /// menu (Toggle Panel / Quit). Distinguishing the two requires *not*
    /// assigning `statusItem.menu` permanently — instead the menu is
    /// attached only for the duration of a right-click, via the standard
    /// "assign menu, performClick, detach menu" trick, so `NSStatusItem`
    /// pops it up itself.
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            let menu = makeMenu()
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else {
            togglePanel()
        }
    }

    /// Dock icon click: the standard reopen behavior is to bring up the
    /// app's window, which for Nickel means showing the panel if it's
    /// hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let panel, !panel.isVisible {
            panel.toggle()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        trustPollTimer?.invalidate()
        noteStore.saveNow()
    }
}

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: FloatingPanel?
    private var trustPollTimer: Timer?

    private let noteStore = NoteStore()
    private var isCapturing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()

        let panel = FloatingPanel(store: noteStore)
        self.panel = panel

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "square.and.pencil",
                accessibilityDescription: "Nickel"
            )
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // Intentionally not `item.menu = ...`: setting `menu` directly makes
        // *every* click (left or right) show the menu instead of reaching
        // `statusItemClicked`. The menu is instead assigned on demand for a
        // right-click only, in `statusItemClicked`.
        statusItem = item

        HotkeyMonitor.shared.onDoubleShift = { [weak self] in self?.handleDoubleShift() }
        startHotkeyMonitorOrPromptForAccess()

        panel.toggle()
    }

    private func startHotkeyMonitorOrPromptForAccess() {
        if Permissions.isTrusted {
            HotkeyMonitor.shared.start()
            return
        }

        // Triggers the native "Nickel.app would like to control this
        // computer" system dialog, which also registers Nickel in the
        // Accessibility list.
        Permissions.requestIfNeeded()

        trustPollTimer?.invalidate()
        trustPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard Permissions.isTrusted else { return }
            timer.invalidate()
            self.trustPollTimer = nil
            HotkeyMonitor.shared.start()
        }
    }

    private func handleDoubleShift() {
        // The panel is a nonactivating NSPanel, so it can be key without
        // being the frontmost app; while it's key the user is interacting
        // with it (selecting notes, renaming a list, typing), so
        // double-shift dismisses it instead of triggering a new capture
        // (in-progress edits commit via the existing focus-loss paths).
        if panel?.isKeyWindow == true {
            debugLog("handleDoubleShift: panel is key window, hiding it")
            panel?.toggle()
            return
        }
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
                    self.panel?.toggle()
                }
            }
        }
    }

    /// Nickel is `LSUIElement` (no Dock icon, no visible menu bar), but AppKit
    /// still routes key equivalents (⌘Q, ⌘C/V/X/A, ⌘Z) through the app's main
    /// menu regardless of whether it's ever shown. Without one, ⌘Q can't quit
    /// the app and standard text editing shortcuts don't work in the search
    /// field, composer, or inline note editors. This installs the minimal
    /// menu needed for that routing to work; it's never visible to the user.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            NSMenuItem(title: "Quit Nickel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

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
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        )
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        if !Permissions.isTrusted {
            let grantItem = NSMenuItem(
                title: "Grant Accessibility Access…",
                action: #selector(grantAccessibilityAccess),
                keyEquivalent: ""
            )
            grantItem.target = self
            menu.addItem(grantItem)
            menu.addItem(.separator())
        }

        let toggleItem = NSMenuItem(
            title: "Toggle Panel",
            action: #selector(togglePanel),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Nickel",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        return menu
    }

    @objc private func togglePanel() {
        panel?.toggle()
    }

    @objc private func grantAccessibilityAccess() {
        Permissions.openAccessibilitySettings()
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

    func applicationWillTerminate(_ notification: Notification) {
        trustPollTimer?.invalidate()
        noteStore.saveNow()
    }
}

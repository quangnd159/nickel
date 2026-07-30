import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: FloatingPanel?
    private var trustPollTimer: Timer?
    /// Set once we've fired the native Input Monitoring prompt, so the poll
    /// timer never requests it twice.
    private var requestedInputMonitoring = false

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

        // Dev/test override: NICKEL_SHOW_PANEL=1 opens the panel immediately
        // at launch, so it can be screenshotted without Accessibility access.
        if ProcessInfo.processInfo.environment["NICKEL_SHOW_PANEL"] == "1" {
            panel.toggle()
        }
    }

    /// Global hotkey detection needs both Accessibility (`AXIsProcessTrusted`)
    /// and Input Monitoring (`IOHIDCheckAccess`) on recent macOS. The two
    /// native prompts are staggered rather than fired together: Input
    /// Monitoring is only requested once Accessibility is already granted,
    /// so the user isn't hit with two system dialogs at once.
    private func startHotkeyMonitorOrPromptForAccess() {
        if Permissions.isTrusted && Permissions.hasInputMonitoring {
            HotkeyMonitor.shared.start()
            return
        }

        if !Permissions.isTrusted {
            // Triggers the native "Nickel.app would like to control this
            // computer" system dialog, which also registers Nickel in the
            // Accessibility list.
            Permissions.requestIfNeeded()
        } else if !Permissions.hasInputMonitoring {
            requestedInputMonitoring = true
            Permissions.requestInputMonitoring()
        }

        trustPollTimer?.invalidate()
        trustPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard Permissions.isTrusted else { return }
            guard Permissions.hasInputMonitoring else {
                if !self.requestedInputMonitoring {
                    self.requestedInputMonitoring = true
                    Permissions.requestInputMonitoring()
                }
                return
            }
            timer.invalidate()
            self.trustPollTimer = nil
            HotkeyMonitor.shared.start()
        }
    }

    private func handleDoubleShift() {
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
                    CaptureHUD.shared.show()
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
        } else if !Permissions.hasInputMonitoring {
            let grantItem = NSMenuItem(
                title: "Grant Input Monitoring…",
                action: #selector(grantInputMonitoringAccess),
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

    @objc private func grantInputMonitoringAccess() {
        Permissions.openInputMonitoringSettings()
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

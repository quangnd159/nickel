import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: FloatingPanel?
    private var trustPollTimer: Timer?

    private let noteStore = NoteStore()
    private var isCapturing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

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

    private func startHotkeyMonitorOrPromptForAccess() {
        if Permissions.isTrusted {
            HotkeyMonitor.shared.start()
            return
        }

        // Triggers the native "Nickel.app would like to control this computer"
        // system dialog, which also registers Nickel in the Accessibility list.
        // This is the single onboarding surface; we don't show a custom window
        // on top of it.
        Permissions.requestIfNeeded()

        trustPollTimer?.invalidate()
        trustPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard Permissions.isTrusted else { return }
            timer.invalidate()
            self?.trustPollTimer = nil
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

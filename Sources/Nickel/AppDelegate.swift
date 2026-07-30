import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: FloatingPanel?
    private var onboardingWindow: PermissionsOnboardingWindow?

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
    }

    private func startHotkeyMonitorOrPromptForAccess() {
        if Permissions.isTrusted {
            HotkeyMonitor.shared.start()
            return
        }

        Permissions.requestIfNeeded()

        let window = PermissionsOnboardingWindow()
        window.onGranted = { [weak self] in
            HotkeyMonitor.shared.start()
            self?.onboardingWindow = nil
        }
        window.startPolling()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
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
        noteStore.saveNow()
    }
}

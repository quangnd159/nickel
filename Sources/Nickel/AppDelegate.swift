import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: FloatingPanel?
    private var onboardingWindow: PermissionsOnboardingWindow?

    private let capturedStore = CapturedStore()
    private var isCapturing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let panel = FloatingPanel(store: capturedStore)
        self.panel = panel

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "circle.circle",
                accessibilityDescription: "Nickel"
            )
        }
        item.menu = makeMenu()
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
                    self.capturedStore.add(text: text, app: appName)
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
}

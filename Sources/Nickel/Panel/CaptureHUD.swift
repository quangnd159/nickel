import AppKit

/// A borderless, non-activating panel that can never become key or main.
///
/// The crash this used to work around (`-[NSRemoteView containingWindowWillOrderOnScreen:]`
/// aborting on `orderFrontRegardless()`) traced back to `NSHostingView`: hosting SwiftUI
/// content spins up a ViewBridge remote view whose order-on-screen observer could throw.
/// Recreating this panel per-toast didn't help because the SwiftUI content view was
/// recreated right along with it. The real fix is below: the HUD's content is now plain
/// AppKit (see `HUDContentView`), so this window never hosts a remote view at all. The
/// panel is still recreated per call, which is cheap and keeps its lifetime tightly
/// scoped to a single toast.
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A tiny "Captured" confirmation toast near the top-right of the screen.
///
/// Each call to `show()` creates a fresh HUD window, runs the fade-in/hold/fade-out
/// timeline, then closes and releases it — nothing is reused across captures.
enum CaptureHUD {
    private static var current: HUDInstance?

    static func show(message: String = "Captured", symbolName: String = "checkmark.circle.fill") {
        if Thread.isMainThread {
            showOnMain(message: message, symbolName: symbolName)
        } else {
            DispatchQueue.main.async { showOnMain(message: message, symbolName: symbolName) }
        }
    }

    private static func showOnMain(message: String, symbolName: String) {
        assert(Thread.isMainThread, "CaptureHUD.show() must run on the main thread")

        // Rapid captures shouldn't stack: cancel and dismiss whatever is currently showing.
        current?.dismissImmediately()
        current = nil

        let instance = HUDInstance()
        current = instance
        instance.onFinished = { [weak instance] in
            if current === instance {
                current = nil
            }
        }
        instance.show(message: message, symbolName: symbolName)
    }
}

/// Owns exactly one HUD window for the duration of a single "Captured" toast.
private final class HUDInstance {
    private var panel: HUDPanel?
    private var hideWorkItem: DispatchWorkItem?
    var onFinished: (() -> Void)?

    func show(message: String, symbolName: String) {
        let panel = makePanel(message: message, symbolName: symbolName)
        self.panel = panel

        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        let workItem = DispatchWorkItem { [weak self] in self?.fadeOutAndClose() }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: workItem)
    }

    /// Cancels any pending fade/close work and tears the window down right away.
    func dismissImmediately() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        close()
    }

    private func fadeOutAndClose() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.close()
        }
    }

    private func close() {
        guard let panel else { return }
        self.panel = nil
        panel.orderOut(nil)
        panel.close()
        onFinished?()
    }

    private func makePanel(message: String, symbolName: String) -> HUDPanel {
        let width = HUDContentView.width(forMessage: message)
        let panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: width, height: 40)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = HUDContentView(message: message, symbolName: symbolName)
        position(panel)
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let margin: CGFloat = 24
        let origin = NSPoint(
            x: screenFrame.maxX - panel.frame.width - margin,
            y: screenFrame.maxY - panel.frame.height - margin
        )
        panel.setFrameOrigin(origin)
    }
}

/// Plain-AppKit "Captured" capsule: a blurred backing, a checkmark glyph, and a label.
/// Deliberately contains no SwiftUI (no `NSHostingView`) so the HUD window can't host a
/// ViewBridge remote view — see the note on `HUDPanel` above.
private final class HUDContentView: NSView {
    init(message: String, symbolName: String) {
        super.init(frame: .zero)

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),

            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Sized to fit the message (icon + margins + text), with a floor matching the
    /// original fixed-width "Captured" toast so short messages don't look cramped.
    static func width(forMessage message: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let textWidth = (message as NSString).size(withAttributes: [.font: font]).width
        let chrome: CGFloat = 14 + 13 + 6 + 14 // leading margin + icon + spacing + trailing margin
        return max(140, ceil(textWidth + chrome))
    }

    override func layout() {
        super.layout()
        wantsLayer = true
        layer?.cornerRadius = bounds.height / 2
        layer?.masksToBounds = true
    }
}

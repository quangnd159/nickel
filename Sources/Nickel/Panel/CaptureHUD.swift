import AppKit
import SwiftUI

/// A borderless, non-activating panel that can never become key or main.
///
/// A long-lived, reused `NSPanel` accumulates AppKit-internal state (remote-view
/// observers, order-on-screen notification wiring, etc.) the longer it stays alive.
/// Under some conditions re-ordering that same window back on screen has been
/// observed to raise an uncaught ObjC exception deep in AppKit
/// (`-[NSRemoteView containingWindowWillOrderOnScreen:]`) which aborts the process.
/// To avoid depending on that window's history at all, every `CaptureHUD.show()`
/// call creates a brand new instance of this panel and tears it down when done.
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

    static func show() {
        if Thread.isMainThread {
            showOnMain()
        } else {
            DispatchQueue.main.async { showOnMain() }
        }
    }

    private static func showOnMain() {
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
        instance.show()
    }
}

/// Owns exactly one HUD window for the duration of a single "Captured" toast.
private final class HUDInstance {
    private var panel: HUDPanel?
    private var hideWorkItem: DispatchWorkItem?
    var onFinished: (() -> Void)?

    func show() {
        let panel = makePanel()
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

    private func makePanel() -> HUDPanel {
        let panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 140, height: 40)),
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
        panel.contentView = NSHostingView(rootView: CaptureHUDView())
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

private struct CaptureHUDView: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
            Text("Captured")
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(VisualEffectBackground(material: .hudWindow))
        .clipShape(Capsule())
    }
}

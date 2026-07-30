import AppKit
import SwiftUI

/// A tiny reusable "Captured" confirmation toast near the top-right of the screen.
final class CaptureHUD {
    static let shared = CaptureHUD()

    private var window: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    private init() {}

    func show() {
        let window = window ?? makeWindow()

        hideWorkItem?.cancel()
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            window.animator().alphaValue = 1
        }

        let workItem = DispatchWorkItem { [weak self] in self?.fadeOutAndClose() }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: workItem)
    }

    private func fadeOutAndClose() {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            window.animator().alphaValue = 0
        } completionHandler: {
            window.orderOut(nil)
        }
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 140, height: 40)),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.alphaValue = 0
        panel.contentView = NSHostingView(rootView: CaptureHUDView())
        position(panel)
        window = panel
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

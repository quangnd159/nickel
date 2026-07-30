import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    convenience init(store: CapturedStore) {
        let size = NSSize(width: 360, height: 560)
        self.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        contentView = NSHostingView(rootView: PanelView().environmentObject(store))

        positionNearTopRight()
    }

    override var canBecomeKey: Bool { true }

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

    func toggle() {
        if isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                animator().alphaValue = 0
            } completionHandler: {
                self.orderOut(nil)
            }
        } else {
            alphaValue = 0
            makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                animator().alphaValue = 1
            }
        }
    }

    override func cancelOperation(_ sender: Any?) {
        toggle()
    }
}

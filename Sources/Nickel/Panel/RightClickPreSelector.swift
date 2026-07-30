import SwiftUI
import AppKit

/// Invisible overlay that observes right mouse-down events landing inside its
/// bounds and reports them, without consuming the event, so SwiftUI's normal
/// `.contextMenu` presentation still happens afterwards. Used so a
/// right-click on a note card can adjust the selection *before* the context
/// menu opens, per the spec: "right-clicking an unselected note first
/// selects only it".
struct RightClickPreSelector: NSViewRepresentable {
    var onRightClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(on: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onRightClick = onRightClick
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onRightClick: onRightClick)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        var onRightClick: () -> Void
        private var monitor: Any?

        init(onRightClick: @escaping () -> Void) {
            self.onRightClick = onRightClick
        }

        func install(on view: NSView) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak view, weak self] event in
                guard let self, let view, let window = view.window, event.window === window else {
                    return event
                }
                let point = view.convert(event.locationInWindow, from: nil)
                if view.bounds.contains(point) {
                    self.onRightClick()
                }
                return event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        deinit {
            removeMonitor()
        }
    }
}

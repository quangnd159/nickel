import AppKit
import ApplicationServices
import SwiftUI

enum Permissions {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestIfNeeded() -> Bool {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options)
    }
}

/// Standard titled window explaining why Nickel needs Accessibility access,
/// with a shortcut to System Settings and a poller that detects when access is granted.
final class PermissionsOnboardingWindow: NSWindow {
    private var pollTimer: Timer?
    var onGranted: (() -> Void)?

    convenience init() {
        self.init(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 420, height: 240)),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        title = "Accessibility Access Needed"
        isReleasedWhenClosed = false
        center()

        contentView = NSHostingView(rootView: PermissionsOnboardingView(
            onOpenSettings: { PermissionsOnboardingWindow.openAccessibilitySettings() }
        ))
    }

    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard Permissions.isTrusted else { return }
            self?.stopPolling()
            self?.close()
            self?.onGranted?()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private struct PermissionsOnboardingView: View {
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            Text("Nickel needs Accessibility access to detect double-Shift and capture selected text.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Accessibility Settings", action: onOpenSettings)
                .keyboardShortcut(.defaultAction)

            Text("Nickel will detect the change automatically once access is granted.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

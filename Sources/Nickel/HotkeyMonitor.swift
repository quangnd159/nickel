import AppKit

/// Detects a system-wide double-tap of the Shift key: two clean shift-down/shift-up
/// cycles, each undisturbed by any other key or modifier, within 350ms of each other.
final class HotkeyMonitor {
    static let shared = HotkeyMonitor()

    var onDoubleShift: (() -> Void)?

    private static let relevantModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
    private static let maxTapInterval: TimeInterval = 0.35

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private var previousModifiers: NSEvent.ModifierFlags = []
    private var shiftIsDownAlone = false
    private var currentTapDisqualified = false
    private var lastTapDate: Date?

    private init() {}

    func start() {
        guard Permissions.isTrusted, Permissions.hasInputMonitoring, globalMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handle(event)
            return event
        }

        debugLog(
            "HotkeyMonitor.start: isTrusted=\(Permissions.isTrusted) " +
            "hasInputMonitoring=\(Permissions.hasInputMonitoring); monitors installed"
        )
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        reset()
    }

    private func reset() {
        previousModifiers = []
        shiftIsDownAlone = false
        currentTapDisqualified = false
        lastTapDate = nil
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            handleFlagsChanged(event)
        case .keyDown:
            handleKeyDown()
        default:
            break
        }
    }

    private func handleKeyDown() {
        // A real key press while Shift is held alone means Shift is being used as a
        // modifier (typing a capital letter, ⌘⇧C, etc.), not a plain tap.
        if shiftIsDownAlone {
            currentTapDisqualified = true
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(Self.relevantModifiers)
        defer { previousModifiers = modifiers }

        if modifiers == [.shift] && previousModifiers.isEmpty {
            shiftIsDownAlone = true
            currentTapDisqualified = false
        } else if modifiers.isEmpty && previousModifiers == [.shift] && shiftIsDownAlone {
            shiftIsDownAlone = false
            let wasQualified = !currentTapDisqualified
            currentTapDisqualified = false
            if wasQualified {
                registerTap()
            }
        } else if shiftIsDownAlone {
            // Some other modifier joined in (e.g. Shift+Command) before Shift was released.
            currentTapDisqualified = true
        }
    }

    private func registerTap() {
        let now = Date()
        if let lastTapDate, now.timeIntervalSince(lastTapDate) <= Self.maxTapInterval {
            self.lastTapDate = nil
            debugLog("tap 2 -> fire")
            onDoubleShift?()
        } else {
            lastTapDate = now
            debugLog("tap 1")
        }
    }
}

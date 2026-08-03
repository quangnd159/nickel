import AppKit

/// Which physical Shift key a tap came from.
enum ShiftSide {
    case left
    case right
}

/// Detects a system-wide double-tap of either Shift key: two clean shift-down/shift-up
/// cycles, each undisturbed by any other key or modifier, within 350ms of each other.
/// The two taps must land on the *same* side (both left or both right); a tap on the
/// other side starts a new sequence for that side instead of completing this one.
///
/// Also reports every ⌘V keyDown it sees via `onCommandV`, for
/// `SequentialPasteCoordinator`: it needs a system-wide ⌘V observer, and
/// this monitor already taps `.keyDown` globally and locally, so it's
/// reused rather than installing a second tap for the same event type.
final class HotkeyMonitor {
    static let shared = HotkeyMonitor()

    var onDoubleShift: ((ShiftSide) -> Void)?
    var onCommandV: ((NSEvent) -> Void)?

    private static let relevantModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
    private static let maxTapInterval: TimeInterval = 0.35
    private static let leftShiftKeyCode: UInt16 = 56
    private static let rightShiftKeyCode: UInt16 = 60
    private static let vKeyCode: UInt16 = 9

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private var previousModifiers: NSEvent.ModifierFlags = []
    private var shiftIsDownAlone = false
    private var currentTapDisqualified = false
    private var currentTapSide: ShiftSide?
    private var lastTapSide: ShiftSide?
    private var lastTapDate: Date?

    private init() {}

    func start() {
        guard Permissions.isTrusted, globalMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handle(event)
            return event
        }

        debugLog("HotkeyMonitor.start: isTrusted=\(Permissions.isTrusted); monitors installed")
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
        currentTapSide = nil
        lastTapSide = nil
        lastTapDate = nil
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            handleFlagsChanged(event)
        case .keyDown:
            handleKeyDown(event)
        default:
            break
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        // A real key press while Shift is held alone means Shift is being used as a
        // modifier (typing a capital letter, ⌘⇧C, etc.), not a plain tap.
        if shiftIsDownAlone {
            currentTapDisqualified = true
        }

        if event.keyCode == Self.vKeyCode && event.modifierFlags.contains(.command) {
            onCommandV?(event)
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(Self.relevantModifiers)
        defer { previousModifiers = modifiers }

        if modifiers == [.shift] && previousModifiers.isEmpty {
            shiftIsDownAlone = true
            currentTapDisqualified = false
            currentTapSide = side(for: event.keyCode)
        } else if modifiers.isEmpty && previousModifiers == [.shift] && shiftIsDownAlone {
            shiftIsDownAlone = false
            let wasQualified = !currentTapDisqualified
            currentTapDisqualified = false
            if wasQualified, let side = currentTapSide {
                registerTap(side: side)
            }
            currentTapSide = nil
        } else if shiftIsDownAlone {
            // Some other modifier joined in (e.g. Shift+Command) before Shift was released.
            currentTapDisqualified = true
        }
    }

    private func side(for keyCode: UInt16) -> ShiftSide? {
        switch keyCode {
        case Self.leftShiftKeyCode: return .left
        case Self.rightShiftKeyCode: return .right
        default: return nil
        }
    }

    private func registerTap(side: ShiftSide) {
        let now = Date()
        // Only two taps on the same side, within the window, count as a double-tap;
        // a tap on the other side becomes the first tap of a new sequence.
        if let lastTapDate, let lastTapSide, lastTapSide == side, now.timeIntervalSince(lastTapDate) <= Self.maxTapInterval {
            self.lastTapDate = nil
            self.lastTapSide = nil
            debugLog("tap 2 (\(side)) -> fire")
            onDoubleShift?(side)
        } else {
            lastTapDate = now
            lastTapSide = side
            debugLog("tap 1 (\(side))")
        }
    }
}

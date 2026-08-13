import AppKit

/// One of the 8 physical modifier keys a tap can be bound to. Caps Lock and
/// Fn are excluded: Caps Lock is a toggle (no clean down/up tap), and Fn
/// doesn't appear in `NSEvent.modifierFlags` the same way on all keyboards.
enum ModifierKey: String, CaseIterable {
    case leftShift, rightShift
    case leftControl, rightControl
    case leftOption, rightOption
    case leftCommand, rightCommand

    /// `keyCode` from a `.flagsChanged` NSEvent for this physical key.
    init?(keyCode: UInt16) {
        switch keyCode {
        case 56: self = .leftShift
        case 60: self = .rightShift
        case 59: self = .leftControl
        case 62: self = .rightControl
        case 58: self = .leftOption
        case 61: self = .rightOption
        case 55: self = .leftCommand
        case 54: self = .rightCommand
        default: return nil
        }
    }

    /// The `.flagsChanged` NSEvent `keyCode` for this physical key. Inverse
    /// of `init(keyCode:)`.
    var keyCode: UInt16 {
        switch self {
        case .leftShift: return 56
        case .rightShift: return 60
        case .leftControl: return 59
        case .rightControl: return 62
        case .leftOption: return 58
        case .rightOption: return 61
        case .leftCommand: return 55
        case .rightCommand: return 54
        }
    }

    /// The `NSEvent.ModifierFlags` bit this key sets. Left and right
    /// siblings share one flag (e.g. both Shifts set `.shift`), which is why
    /// the tap detector has to disambiguate by `keyCode`, not by flag alone.
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .leftShift, .rightShift: return .shift
        case .leftControl, .rightControl: return .control
        case .leftOption, .rightOption: return .option
        case .leftCommand, .rightCommand: return .command
        }
    }

    /// User-facing name for the Settings pickers, led by the key's standard
    /// glyph the way macOS renders modifiers everywhere, e.g. "⇧ Left Shift".
    var displayName: String {
        switch self {
        case .leftShift: return "⇧ Left Shift"
        case .rightShift: return "⇧ Right Shift"
        case .leftControl: return "⌃ Left Control"
        case .rightControl: return "⌃ Right Control"
        case .leftOption: return "⌥ Left Option"
        case .rightOption: return "⌥ Right Option"
        case .leftCommand: return "⌘ Left Command"
        case .rightCommand: return "⌘ Right Command"
        }
    }
}

/// Detects a system-wide double-tap of any of the 8 physical modifier keys:
/// two clean down/up cycles, each undisturbed by any other key or modifier,
/// within 350ms of each other. The two taps must land on the *same* physical
/// key (e.g. both Left Shift); a tap on a different key starts a new
/// sequence for that key instead of completing this one.
///
/// Also reports every ⌘V keyDown it sees via `onCommandV`, for
/// `SequentialPasteCoordinator`: it needs a system-wide ⌘V observer, and
/// this monitor already taps `.keyDown` globally and locally, so it's
/// reused rather than installing a second tap for the same event type.
final class HotkeyMonitor {
    static let shared = HotkeyMonitor()

    var onDoubleTap: ((ModifierKey) -> Void)?
    var onCommandV: ((NSEvent) -> Void)?

    private static let relevantModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
    static let maxTapInterval: TimeInterval = 0.35
    private static let vKeyCode: UInt16 = 9

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private var previousModifiers: NSEvent.ModifierFlags = []
    private var keyIsDownAlone = false
    private var currentTapDisqualified = false
    private var currentTapKey: ModifierKey?
    private var lastTapKey: ModifierKey?
    private var lastTapDate: Date?

    /// Injected clock, so tests can drive the 350ms window deterministically
    /// instead of the state machine depending on wall-clock time.
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

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
        keyIsDownAlone = false
        currentTapDisqualified = false
        currentTapKey = nil
        lastTapKey = nil
        lastTapDate = nil
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            handleFlagsChanged(modifiers: event.modifierFlags, keyCode: event.keyCode)
        case .keyDown:
            handleKeyDown(event)
        default:
            break
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        disqualifyCurrentTap()

        if event.keyCode == Self.vKeyCode && event.modifierFlags.contains(.command) {
            onCommandV?(event)
        }
    }

    // MARK: - Pure tap-detection state machine
    //
    // `handleFlagsChanged` and `disqualifyCurrentTap` are `internal`, not
    // `private`, so tests can drive them directly with synthetic keyCodes
    // and modifier flags instead of constructing real NSEvents.

    /// Given the physical key that changed and the modifiers now held,
    /// advances the tap state machine and fires `onDoubleTap` when a
    /// qualifying second tap completes.
    func handleFlagsChanged(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) {
        let relevant = modifiers.intersection(Self.relevantModifiers)
        defer { previousModifiers = relevant }

        if let key = ModifierKey(keyCode: keyCode), relevant == [key.flag], previousModifiers.isEmpty {
            keyIsDownAlone = true
            currentTapDisqualified = false
            currentTapKey = key
        } else if relevant.isEmpty, let key = currentTapKey, keyIsDownAlone {
            keyIsDownAlone = false
            let wasQualified = !currentTapDisqualified
            currentTapDisqualified = false
            currentTapKey = nil
            if wasQualified {
                registerTap(key: key)
            }
        } else if keyIsDownAlone {
            // Some other modifier joined (e.g. Shift+Command), or the same
            // flag came from the sibling key (e.g. both Shifts down) before
            // this one was released.
            currentTapDisqualified = true
        }
    }

    /// A real key press (or the sibling of the held key going down too)
    /// while a modifier is held alone means it's being used as a modifier,
    /// not a plain tap.
    func disqualifyCurrentTap() {
        if keyIsDownAlone {
            currentTapDisqualified = true
        }
    }

    private func registerTap(key: ModifierKey) {
        let tapTime = now()
        // Only two taps on the same physical key, within the window, count
        // as a double-tap; a tap on a different key becomes the first tap
        // of a new sequence.
        if let lastTapDate, let lastTapKey, lastTapKey == key, tapTime.timeIntervalSince(lastTapDate) <= Self.maxTapInterval {
            self.lastTapDate = nil
            self.lastTapKey = nil
            debugLog("tap 2 (\(key)) -> fire")
            onDoubleTap?(key)
        } else {
            lastTapDate = tapTime
            lastTapKey = key
            debugLog("tap 1 (\(key))")
        }
    }
}

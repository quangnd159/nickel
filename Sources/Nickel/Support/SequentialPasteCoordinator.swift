import AppKit

/// Splits one user ⌘V into two pastes so a mixed copy (text + attachments)
/// lands whole in apps that only read one pasteboard flavor per paste
/// (Copper's trick; empirically true of many chat composers).
///
/// The flow: `PanelActions` copies as usual, then arms this coordinator when
/// the batch is mixed. Arming stages an *attachments-only* layout on the
/// general pasteboard. The user's real ⌘V lands in whatever app is
/// frontmost and delivers the attachments (that's all the pasteboard has).
/// Shortly after, this coordinator swaps in a *text-only* layout and posts
/// one synthetic ⌘V of its own, so the same app's composer receives the text
/// as a second, distinct paste. It then re-stages attachments-only so the
/// sequence can repeat on the next real ⌘V, until disarmed.
///
/// This class is the testable state machine: it takes an injected paste
/// poster and scheduler so its logic runs headlessly. The CGEvent tap that
/// observes real ⌘V keystrokes and the CGEvent poster that fabricates the
/// synthetic one are thin, unit-untestable glue layered on top (see
/// `HotkeyMonitor.onCommandV` and `postSyntheticCommandV()` below), the same
/// split the project already uses for `HotkeyMonitor` vs. `CaptureEngine`.
final class SequentialPasteCoordinator {
    enum State: Equatable {
        case idle
        case armed
        case firing
    }

    /// Delay between the real ⌘V (which delivers the attachments) and
    /// swapping the clipboard to text-only for the synthetic paste. Long
    /// enough that the target app has processed the first paste before the
    /// clipboard changes under it.
    static let textSwapDelay: TimeInterval = 0.2
    /// Delay after the synthetic paste before re-staging attachments-only,
    /// so the target app's paste handler has finished reading the text-only
    /// layout before the clipboard changes again.
    static let restageDelay: TimeInterval = 0.3
    /// How long an armed (or re-armed) state survives without a ⌘V before
    /// disarming on its own, restarted every time a sequence fires.
    static let disarmTimeout: TimeInterval = 60

    /// Marks CGEvents this coordinator posts itself, via
    /// `CGEvent.setIntegerValueField(.eventSourceUserData, value:)`, so the
    /// ⌘V observer can ignore its own synthetic keystroke instead of
    /// treating it as a second real user paste (which would otherwise loop).
    static let syntheticEventUserData: Int64 = 0x4E49434B454C5054 // "NICKELPT"

    static let shared = SequentialPasteCoordinator(postSyntheticPaste: postSyntheticCommandV)

    private(set) var state: State = .idle

    private let postSyntheticPaste: () -> Void
    private let scheduleAfter: (TimeInterval, @escaping () -> Void) -> Void

    private var staging: SequentialPasteStaging?
    private var lastKnownChangeCount: Int?
    /// Bumped on every arm/disarm so a fire-chain (`fireTextSwap`/`fireRestage`)
    /// started by a since-superseded sequence (re-copy mid-flight, a
    /// disarm) can recognize it's stale and no-op instead of acting on the
    /// wrong staging.
    private var sessionGeneration = 0
    /// Bumped on every `scheduleTimeout()` call (arm *and* restage), tracked
    /// separately from `sessionGeneration` because a restage keeps the same
    /// session but must still invalidate the timeout scheduled before it —
    /// nothing here cancels the underlying scheduled callback (the injected
    /// `scheduleAfter` has no cancel primitive), so both the original and
    /// the restarted timeout stay scheduled and this counter is what makes
    /// only the latest one actually disarm.
    private var timeoutGeneration = 0

    init(
        postSyntheticPaste: @escaping () -> Void,
        scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    ) {
        self.postSyntheticPaste = postSyntheticPaste
        self.scheduleAfter = scheduleAfter
    }

    // MARK: - Copy hook

    /// Called after every panel copy. Arms only when the batch has both
    /// nonempty text and at least one attachment; otherwise makes sure
    /// there's no stale armed state left over from an earlier mixed copy
    /// (the pasteboard already holds this copy's correct full layout, so
    /// disarming here must NOT overwrite it).
    func handleCopy(hasText: Bool, hasAttachments: Bool, staging: SequentialPasteStaging) {
        guard hasText, hasAttachments else {
            disarm(restoreFullLayout: false)
            return
        }
        arm(staging: staging)
    }

    private func arm(staging: SequentialPasteStaging) {
        sessionGeneration += 1
        staging.writeAttachmentsOnly()
        self.staging = staging
        lastKnownChangeCount = staging.changeCount
        state = .armed
        scheduleTimeout()
        debugLog("SequentialPasteCoordinator: armed (session \(sessionGeneration))")
    }

    // MARK: - ⌘V hook

    /// Called for every ⌘V keyDown the observer sees. `isSynthetic` and
    /// `isRepeat` filter out our own posted event and key-repeat; while
    /// `frontmostAppIsNickel` filters out a ⌘V typed inside Nickel itself
    /// (e.g. into the search field), which isn't the "paste into another
    /// app" this coordinator exists for.
    func handleCommandV(isSynthetic: Bool, isRepeat: Bool, frontmostAppIsNickel: Bool) {
        guard !isSynthetic, !isRepeat, !frontmostAppIsNickel else { return }
        guard state == .armed, let staging else { return }

        guard staging.changeCount == lastKnownChangeCount else {
            // Something else changed the clipboard since we staged
            // attachments-only (an external copy). That content is on the
            // pasteboard now, not ours to overwrite — just stop
            // intercepting and let this ⌘V paste whatever's actually there.
            debugLog("SequentialPasteCoordinator: external change detected at fire time, disarming without restore")
            disarm(restoreFullLayout: false)
            return
        }

        state = .firing
        let firingSession = sessionGeneration
        debugLog("SequentialPasteCoordinator: firing (session \(firingSession))")
        scheduleAfter(Self.textSwapDelay) { [weak self] in
            self?.fireTextSwap(session: firingSession)
        }
    }

    private func fireTextSwap(session: Int) {
        guard session == sessionGeneration, state == .firing, let staging else { return }
        staging.writeTextOnly()
        postSyntheticPaste()
        scheduleAfter(Self.restageDelay) { [weak self] in
            self?.fireRestage(session: session)
        }
    }

    private func fireRestage(session: Int) {
        guard session == sessionGeneration, let staging else { return }
        staging.writeAttachmentsOnly()
        lastKnownChangeCount = staging.changeCount
        state = .armed
        scheduleTimeout()
        debugLog("SequentialPasteCoordinator: re-staged, armed (session \(session))")
    }

    // MARK: - Timeout / disarm

    private func scheduleTimeout() {
        timeoutGeneration += 1
        let scheduledTimeoutGeneration = timeoutGeneration
        scheduleAfter(Self.disarmTimeout) { [weak self] in
            self?.timeoutFired(generation: scheduledTimeoutGeneration)
        }
    }

    private func timeoutFired(generation: Int) {
        guard generation == timeoutGeneration, state != .idle, let staging else { return }
        // If the pasteboard still holds exactly what we staged, restore the
        // full layout so a later manual paste of this copy still works. If
        // it's already changed externally, that content isn't ours to
        // overwrite.
        let stillOurs = staging.changeCount == lastKnownChangeCount
        debugLog("SequentialPasteCoordinator: timeout (gen \(generation)), stillOurs=\(stillOurs)")
        disarm(restoreFullLayout: stillOurs)
    }

    private func disarm(restoreFullLayout: Bool) {
        if restoreFullLayout, let staging {
            staging.writeFull()
        }
        sessionGeneration += 1
        timeoutGeneration += 1
        staging = nil
        lastKnownChangeCount = nil
        state = .idle
        debugLog("SequentialPasteCoordinator: idle")
    }
}

// MARK: - Pasteboard staging

/// Abstracts "write this batch's attachments-only / text-only / full layout,
/// read the pasteboard's current changeCount" so
/// `SequentialPasteCoordinator`'s state machine can be driven by fakes in
/// tests instead of a real `NSPasteboard`.
protocol SequentialPasteStaging {
    func writeAttachmentsOnly()
    func writeTextOnly()
    func writeFull()
    var changeCount: Int { get }
}

/// The real staging implementation: writes `PasteboardWriter` layouts to an
/// actual `NSPasteboard`.
struct RealSequentialPasteStaging: SequentialPasteStaging {
    let layout: PasteboardWriter.Layout
    let pasteboard: NSPasteboard

    func writeAttachmentsOnly() {
        PasteboardWriter.writeAttachmentsOnly(layout, pasteboard: pasteboard)
    }

    func writeTextOnly() {
        PasteboardWriter.writeTextOnly(layout, pasteboard: pasteboard)
    }

    func writeFull() {
        PasteboardWriter.write(layout, pasteboard: pasteboard)
    }

    var changeCount: Int { pasteboard.changeCount }
}

extension SequentialPasteCoordinator {
    /// Convenience for real callers (`PanelActions`): derives mixed-ness
    /// from the copied notes and wraps the layout in `RealSequentialPasteStaging`,
    /// then defers to the testable `handleCopy(hasText:hasAttachments:staging:)`.
    func handleCopy(notes: [Note], layout: PasteboardWriter.Layout, pasteboard: NSPasteboard = .general) {
        let hasText = notes.contains { !$0.text.isEmpty }
        let hasAttachments = notes.contains { !$0.attachments.isEmpty }
        handleCopy(
            hasText: hasText,
            hasAttachments: hasAttachments,
            staging: RealSequentialPasteStaging(layout: layout, pasteboard: pasteboard)
        )
    }
}

// MARK: - Synthetic ⌘V poster (real CGEvent glue, not unit-tested)

/// Posts a synthetic ⌘V (keyDown + keyUp, keyCode 9, command flag) to the
/// system HID event tap, marked via `eventSourceUserData` so the ⌘V observer
/// recognizes and ignores it. Mirrors `CaptureEngine.postCommandC()`.
private func postSyntheticCommandV() {
    guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
    let vKeyCode: CGKeyCode = 9

    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
    keyDown?.flags = .maskCommand
    keyDown?.setIntegerValueField(.eventSourceUserData, value: SequentialPasteCoordinator.syntheticEventUserData)
    keyDown?.post(tap: .cghidEventTap)

    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
    keyUp?.flags = .maskCommand
    keyUp?.setIntegerValueField(.eventSourceUserData, value: SequentialPasteCoordinator.syntheticEventUserData)
    keyUp?.post(tap: .cghidEventTap)
}

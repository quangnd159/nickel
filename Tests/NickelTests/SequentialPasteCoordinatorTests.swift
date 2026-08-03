import XCTest
@testable import Nickel

/// A fake `SequentialPasteStaging`: records calls and lets tests drive
/// `changeCount` (including simulating an external app changing the
/// pasteboard behind the coordinator's back).
final class FakeStaging: SequentialPasteStaging {
    private(set) var attachmentsOnlyWriteCount = 0
    private(set) var textOnlyWriteCount = 0
    private(set) var fullWriteCount = 0
    private(set) var callOrder: [String] = []

    var changeCount = 0

    func writeAttachmentsOnly() {
        attachmentsOnlyWriteCount += 1
        callOrder.append("attachmentsOnly")
        changeCount += 1
    }

    func writeTextOnly() {
        textOnlyWriteCount += 1
        callOrder.append("textOnly")
        changeCount += 1
    }

    func writeFull() {
        fullWriteCount += 1
        callOrder.append("full")
        changeCount += 1
    }
}

/// A scheduler double that captures every `(delay, action)` pair instead of
/// waiting in real time. Tests fire specific delays deterministically
/// (`fire(delay:)`) or drain everything queued (`fireAll()`), so the
/// coordinator's ~200ms/~300ms/60s timers never make a test actually sleep.
final class FakeScheduler {
    private(set) var scheduled: [(delay: TimeInterval, action: () -> Void)] = []

    func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) {
        scheduled.append((delay, action))
    }

    /// Fires (and removes) the first pending action scheduled with exactly
    /// this delay.
    func fire(delay: TimeInterval) {
        guard let index = scheduled.firstIndex(where: { $0.delay == delay }) else {
            XCTFail("No action scheduled with delay \(delay)")
            return
        }
        let action = scheduled.remove(at: index).action
        action()
    }

    var isEmpty: Bool { scheduled.isEmpty }
}

final class SequentialPasteCoordinatorTests: XCTestCase {
    private var scheduler: FakeScheduler!
    private var postedPasteCount = 0
    private var coordinator: SequentialPasteCoordinator!

    override func setUp() {
        super.setUp()
        scheduler = FakeScheduler()
        postedPasteCount = 0
        coordinator = SequentialPasteCoordinator(
            postSyntheticPaste: { [weak self] in self?.postedPasteCount += 1 },
            scheduleAfter: { [weak self] delay, action in self?.scheduler.schedule(delay, action) }
        )
    }

    override func tearDown() {
        coordinator = nil
        scheduler = nil
        super.tearDown()
    }

    // MARK: - Arming

    func testMixedCopyArmsAndStagesAttachmentsOnly() {
        let staging = FakeStaging()
        coordinator.handleCopy(hasText: true, hasAttachments: true, staging: staging)

        XCTAssertEqual(coordinator.state, .armed)
        XCTAssertEqual(staging.attachmentsOnlyWriteCount, 1)
        XCTAssertEqual(staging.textOnlyWriteCount, 0)
        XCTAssertEqual(staging.fullWriteCount, 0)
    }

    func testTextOnlyCopyStaysIdleAndDoesNotWrite() {
        let staging = FakeStaging()
        coordinator.handleCopy(hasText: true, hasAttachments: false, staging: staging)

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(staging.attachmentsOnlyWriteCount, 0)
        XCTAssertEqual(staging.textOnlyWriteCount, 0)
        XCTAssertEqual(staging.fullWriteCount, 0)
    }

    func testAttachmentsOnlyCopyStaysIdleAndDoesNotWrite() {
        let staging = FakeStaging()
        coordinator.handleCopy(hasText: false, hasAttachments: true, staging: staging)

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(staging.attachmentsOnlyWriteCount, 0)
    }

    func testEmptyCopyStaysIdle() {
        let staging = FakeStaging()
        coordinator.handleCopy(hasText: false, hasAttachments: false, staging: staging)

        XCTAssertEqual(coordinator.state, .idle)
    }

    // MARK: - User ⌘V while armed

    func testUserCommandVWhileArmedTriggersExactlyOneSyntheticPasteAndRestages() {
        let staging = FakeStaging()
        coordinator.handleCopy(hasText: true, hasAttachments: true, staging: staging)

        coordinator.handleCommandV(isSynthetic: false, isRepeat: false, frontmostAppIsNickel: false)
        XCTAssertEqual(coordinator.state, .firing)
        XCTAssertEqual(postedPasteCount, 0, "paste is posted only after the text-swap delay")

        scheduler.fire(delay: SequentialPasteCoordinator.textSwapDelay)
        XCTAssertEqual(postedPasteCount, 1)
        XCTAssertEqual(staging.textOnlyWriteCount, 1)
        XCTAssertEqual(coordinator.state, .firing, "still firing until the restage delay elapses")

        scheduler.fire(delay: SequentialPasteCoordinator.restageDelay)
        XCTAssertEqual(coordinator.state, .armed)
        XCTAssertEqual(staging.attachmentsOnlyWriteCount, 2, "staged once on arm, again on restage")
        XCTAssertEqual(postedPasteCount, 1, "exactly one synthetic paste per real ⌘V")
    }

    func testCommandVDuringFiringIsIgnored() {
        let staging = FakeStaging()
        coordinator.handleCopy(hasText: true, hasAttachments: true, staging: staging)
        coordinator.handleCommandV(isSynthetic: false, isRepeat: false, frontmostAppIsNickel: false)
        XCTAssertEqual(coordinator.state, .firing)

        // A second real ⌘V arrives before the sequence completes.
        coordinator.handleCommandV(isSynthetic: false, isRepeat: false, frontmostAppIsNickel: false)

        scheduler.fire(delay: SequentialPasteCoordinator.textSwapDelay)
        XCTAssertEqual(postedPasteCount, 1, "the ignored ⌘V must not queue a second fire chain")
    }

    func testSyntheticMarkedEventIsIgnored() {
        let staging = FakeStaging()
        coordinator.handleCopy(hasText: true, hasAttachments: true, staging: staging)

        coordinator.handleCommandV(isSynthetic: true, isRepeat: false, frontmostAppIsNickel: false)

        XCTAssertEqual(coordinator.state, .armed, "our own synthetic paste must not start a new fire sequence")
    }

    func testKeyRepeatIsIgnored() {
        let staging = FakeStaging()
        coordinator.handleCopy(hasText: true, hasAttachments: true, staging: staging)

        coordinator.handleCommandV(isSynthetic: false, isRepeat: true, frontmostAppIsNickel: false)

        XCTAssertEqual(coordinator.state, .armed)
    }

    func testCommandVWhileNickelIsFrontmostIsIgnored() {
        let staging = FakeStaging()
        coordinator.handleCopy(hasText: true, hasAttachments: true, staging: staging)

        coordinator.handleCommandV(isSynthetic: false, isRepeat: false, frontmostAppIsNickel: true)

        XCTAssertEqual(coordinator.state, .armed)
    }

    func testCommandVWhileIdleIsNoOp() {
        coordinator.handleCommandV(isSynthetic: false, isRepeat: false, frontmostAppIsNickel: false)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(postedPasteCount, 0)
    }

    // MARK: - External change disarms

    func testExternalChangeDetectedAtFireTimeDisarmsWithoutRestoring() {
        let staging = FakeStaging()
        coordinator.handleCopy(hasText: true, hasAttachments: true, staging: staging)

        // Someone else copies something, bumping changeCount past what we
        // last wrote.
        staging.changeCount += 1

        coordinator.handleCommandV(isSynthetic: false, isRepeat: false, frontmostAppIsNickel: false)

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(staging.fullWriteCount, 0, "must not clobber the external app's clipboard content")
        XCTAssertEqual(postedPasteCount, 0)
    }

    func testTimeoutWithUnchangedPasteboardDisarmsAndRestoresFullLayout() {
        let staging = FakeStaging()
        coordinator.handleCopy(hasText: true, hasAttachments: true, staging: staging)

        scheduler.fire(delay: SequentialPasteCoordinator.disarmTimeout)

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(staging.fullWriteCount, 1)
    }

    func testTimeoutAfterExternalChangeDisarmsWithoutRestoring() {
        let staging = FakeStaging()
        coordinator.handleCopy(hasText: true, hasAttachments: true, staging: staging)

        staging.changeCount += 1 // external copy landed since we armed

        scheduler.fire(delay: SequentialPasteCoordinator.disarmTimeout)

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(staging.fullWriteCount, 0)
    }

    func testTimeoutRestartsOnEachFire() {
        let staging = FakeStaging()
        coordinator.handleCopy(hasText: true, hasAttachments: true, staging: staging)

        coordinator.handleCommandV(isSynthetic: false, isRepeat: false, frontmostAppIsNickel: false)
        scheduler.fire(delay: SequentialPasteCoordinator.textSwapDelay)
        scheduler.fire(delay: SequentialPasteCoordinator.restageDelay)

        // Restaging schedules a fresh 60s timeout on top of the one from
        // arm time (nothing cancels the old one — see
        // `testStaleTimeoutFromBeforeARestageDoesNothing` for proof the
        // stale one is inert), so both remain queued.
        XCTAssertEqual(scheduler.scheduled.filter { $0.delay == SequentialPasteCoordinator.disarmTimeout }.count, 2)
    }

    func testStaleTimeoutFromBeforeARestageDoesNothing() {
        let staging = FakeStaging()
        coordinator.handleCopy(hasText: true, hasAttachments: true, staging: staging)

        // Capture the original arm-time timeout before firing a full round.
        let originalTimeouts = scheduler.scheduled.filter { $0.delay == SequentialPasteCoordinator.disarmTimeout }
        XCTAssertEqual(originalTimeouts.count, 1)

        coordinator.handleCommandV(isSynthetic: false, isRepeat: false, frontmostAppIsNickel: false)
        scheduler.fire(delay: SequentialPasteCoordinator.textSwapDelay)
        scheduler.fire(delay: SequentialPasteCoordinator.restageDelay)
        XCTAssertEqual(coordinator.state, .armed)

        // Manually invoke the stale original timeout action (simulating it
        // firing late); it must be a no-op since re-staging bumped the
        // generation.
        originalTimeouts[0].action()
        XCTAssertEqual(coordinator.state, .armed, "a stale timeout must not disarm a freshly re-armed sequence")
        XCTAssertEqual(staging.fullWriteCount, 0)
    }

    // MARK: - Re-copy re-arms

    func testReCopyWhileArmedRearmsWithFreshStaging() {
        let firstStaging = FakeStaging()
        coordinator.handleCopy(hasText: true, hasAttachments: true, staging: firstStaging)
        XCTAssertEqual(coordinator.state, .armed)

        let secondStaging = FakeStaging()
        coordinator.handleCopy(hasText: true, hasAttachments: true, staging: secondStaging)

        XCTAssertEqual(coordinator.state, .armed)
        XCTAssertEqual(secondStaging.attachmentsOnlyWriteCount, 1)

        // A ⌘V now should act on the new staging, not the old one.
        coordinator.handleCommandV(isSynthetic: false, isRepeat: false, frontmostAppIsNickel: false)
        scheduler.fire(delay: SequentialPasteCoordinator.textSwapDelay)
        XCTAssertEqual(secondStaging.textOnlyWriteCount, 1)
        XCTAssertEqual(firstStaging.textOnlyWriteCount, 0)
    }

    func testNonMixedCopyWhileArmedDisarmsWithoutRestoringOverTheNewCopy() {
        let mixedStaging = FakeStaging()
        coordinator.handleCopy(hasText: true, hasAttachments: true, staging: mixedStaging)
        XCTAssertEqual(coordinator.state, .armed)

        // A text-only copy follows; PasteboardWriter already wrote the
        // correct full (text-only) layout for it directly, so the
        // coordinator must go idle WITHOUT writing anything of its own
        // (which would use the stale mixed staging and clobber the new copy).
        let textOnlyStaging = FakeStaging()
        coordinator.handleCopy(hasText: true, hasAttachments: false, staging: textOnlyStaging)

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(mixedStaging.fullWriteCount, 0)
        XCTAssertEqual(textOnlyStaging.fullWriteCount, 0)
        XCTAssertEqual(textOnlyStaging.attachmentsOnlyWriteCount, 0)
    }
}

import AppKit
import XCTest
@testable import Nickel

/// The composer's focus signal, which the "#" suggestion popup and the
/// composer's focus ring both read.
///
/// These drive a real `FloatingPanel` rather than the field in isolation on
/// purpose: the bug these cover was that the *field* can't see every way focus
/// is lost. `NSTextField` hands first responder to the window's field editor,
/// so `textDidEndEditing` fires only when editing actually ends — a panel that
/// merely stops being key keeps the field editor as first responder and
/// reports nothing, leaving the popup floating over an unfocused composer.
final class ComposerFocusTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: NoteStore!
    private var panel: FloatingPanel!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = NoteStore(fileURL: tempDirectory.appendingPathComponent("notes.json"))
        panel = FloatingPanel(store: store)
    }

    override func tearDown() {
        panel.orderOut(nil)
        panel = nil
        store = nil
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        super.tearDown()
    }

    /// A stand-in for the composer's field: the panel hands its custom
    /// drag-rejecting field editor to `GrowingTextField` clients only, which
    /// is exactly how it tells the composer apart from the search field.
    private func makeComposerField() -> GrowingTextField {
        let field = GrowingTextField()
        panel.contentView?.addSubview(field)
        return field
    }

    /// A field that isn't the composer (the search capsule, a header rename,
    /// the palette's query), which gets the window's standard field editor.
    private func makeOtherField() -> NSTextField {
        let field = NSTextField()
        panel.contentView?.addSubview(field)
        return field
    }

    private var isComposerFocused: Bool {
        panel.selectionModelForTesting.isComposerFocused
    }

    private var isSearchFocused: Bool {
        panel.selectionModelForTesting.isSearchFocused
    }

    /// A stand-in for the search field: registered with the panel the same
    /// way `SearchField.updateNSView` registers the real one, since the
    /// search field (unlike the composer) has no field-editor identity of
    /// its own to be told apart by.
    private func makeSearchField() -> NSTextField {
        let field = makeOtherField()
        panel.searchField = field
        return field
    }

    func testFocusingTheComposerSetsTheFlag() {
        let composer = makeComposerField()

        panel.makeKeyAndOrderFront(nil)
        // The test process is never the active app, so AppKit won't grant the
        // window key on its own; call the same entry point it would.
        panel.becomeKey()
        XCTAssertTrue(panel.makeFirstResponder(composer))

        XCTAssertTrue(isComposerFocused)
    }

    func testClickingAwayInsideThePanelClearsTheFlag() {
        // What `handleBackgroundClick` and a note row's tap both do.
        let composer = makeComposerField()
        panel.makeKeyAndOrderFront(nil)
        panel.becomeKey()
        _ = panel.makeFirstResponder(composer)

        _ = panel.makeFirstResponder(nil)

        XCTAssertFalse(isComposerFocused)
    }

    func testFocusingAnotherFieldClearsTheFlag() {
        // Clicking the search capsule: the composer's field editor is gone,
        // but *a* field editor is still first responder — the flag has to
        // track which one.
        let composer = makeComposerField()
        let other = makeOtherField()
        panel.makeKeyAndOrderFront(nil)
        panel.becomeKey()
        _ = panel.makeFirstResponder(composer)

        _ = panel.makeFirstResponder(other)

        XCTAssertFalse(isComposerFocused)
    }

    func testLosingKeyClearsTheFlagEvenThoughEditingNeverEnded() {
        // The regression: clicking another app (or another Nickel window)
        // leaves the composer's field editor as first responder and fires no
        // field-level callback at all.
        let composer = makeComposerField()
        panel.makeKeyAndOrderFront(nil)
        panel.becomeKey()
        _ = panel.makeFirstResponder(composer)

        panel.resignKey()

        XCTAssertTrue(panel.firstResponder is NSTextView, "AppKit really does leave the field editor focused here")
        XCTAssertFalse(isComposerFocused)
    }

    func testRegainingKeyRestoresTheFlagWhenTheComposerStillHasFirstResponder() {
        let composer = makeComposerField()
        panel.makeKeyAndOrderFront(nil)
        panel.becomeKey()
        _ = panel.makeFirstResponder(composer)
        panel.resignKey()

        panel.becomeKey()

        XCTAssertTrue(isComposerFocused)
    }

    func testKeyWindowWithoutTheComposerFocusedLeavesTheFlagClear() {
        let other = makeOtherField()
        panel.makeKeyAndOrderFront(nil)
        panel.becomeKey()
        _ = panel.makeFirstResponder(other)

        panel.becomeKey()

        XCTAssertFalse(isComposerFocused)
    }

    // MARK: - Search focus

    /// The search capsule's substitute ring follows the same signal, one
    /// field over — focusing the search field sets it, and it stays clear of
    /// the composer's own flag.
    func testFocusingTheSearchFieldSetsItsFlagAndNotTheComposers() {
        let search = makeSearchField()

        panel.makeKeyAndOrderFront(nil)
        panel.becomeKey()
        XCTAssertTrue(panel.makeFirstResponder(search))

        XCTAssertTrue(isSearchFocused)
        XCTAssertFalse(isComposerFocused)
    }

    func testFocusingTheComposerLeavesTheSearchFlagClear() {
        let composer = makeComposerField()
        let search = makeSearchField()
        panel.makeKeyAndOrderFront(nil)
        panel.becomeKey()
        _ = panel.makeFirstResponder(search)

        _ = panel.makeFirstResponder(composer)

        XCTAssertFalse(isSearchFocused)
        XCTAssertTrue(isComposerFocused)
    }

    func testLosingKeyClearsTheSearchFlag() {
        let search = makeSearchField()
        panel.makeKeyAndOrderFront(nil)
        panel.becomeKey()
        _ = panel.makeFirstResponder(search)

        panel.resignKey()

        XCTAssertFalse(isSearchFocused)
    }
}

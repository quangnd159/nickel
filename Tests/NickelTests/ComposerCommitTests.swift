import XCTest
@testable import Nickel

/// Tests for the composer's staged-section-chip decision logic
/// (`ComposerCommit.plan`, `ComposerSectionChip`) and how it drives
/// `NoteStore`, mirroring exactly what `PanelView.commitComposer` does —
/// that method itself lives in a SwiftUI view and isn't directly testable.
final class ComposerCommitTests: XCTestCase {
    // MARK: - ComposerCommit.plan

    func testNoChipNoTextNoAttachmentsIsNoop() {
        XCTAssertEqual(ComposerCommit.plan(text: "", hasAttachments: false, pendingSection: nil), .noop)
    }

    func testNoChipBlankTextNoAttachmentsIsNoop() {
        XCTAssertEqual(ComposerCommit.plan(text: "   \n  ", hasAttachments: false, pendingSection: nil), .noop)
    }

    func testNoChipWithTextAddsNoteToActiveSection() {
        XCTAssertEqual(ComposerCommit.plan(text: "hello", hasAttachments: false, pendingSection: nil), .addNote(section: nil))
    }

    func testNoChipWithAttachmentsOnlyAddsNoteToActiveSection() {
        XCTAssertEqual(ComposerCommit.plan(text: "", hasAttachments: true, pendingSection: nil), .addNote(section: nil))
    }

    func testChipWithEmptyTextAndNoAttachmentsIsSectionOnly() {
        XCTAssertEqual(ComposerCommit.plan(text: "  ", hasAttachments: false, pendingSection: "Errands"), .sectionOnly(section: "Errands"))
    }

    func testChipWithTextAddsNoteToChipSection() {
        XCTAssertEqual(ComposerCommit.plan(text: "buy milk", hasAttachments: false, pendingSection: "Errands"), .addNote(section: "Errands"))
    }

    func testChipWithAttachmentsOnlyAddsNoteToChipSection() {
        XCTAssertEqual(ComposerCommit.plan(text: "", hasAttachments: true, pendingSection: "Errands"), .addNote(section: "Errands"))
    }

    // MARK: - ComposerSectionChip staging

    func testStagingSetsChipName() {
        var chip = ComposerSectionChip()
        chip.stage(named: "Work")
        XCTAssertEqual(chip.name, "Work")
    }

    func testStagingTrimsWhitespace() {
        var chip = ComposerSectionChip()
        chip.stage(named: "  Work  ")
        XCTAssertEqual(chip.name, "Work")
    }

    func testStagingBlankNameIsNoop() {
        var chip = ComposerSectionChip()
        chip.stage(named: "   ")
        XCTAssertNil(chip.name)
    }

    func testReplacingAStagedChipKeepsOnlyTheNewOne() {
        var chip = ComposerSectionChip()
        chip.stage(named: "Work")
        chip.stage(named: "Home")
        XCTAssertEqual(chip.name, "Home")
    }

    func testRemovingAStagedChipClearsIt() {
        var chip = ComposerSectionChip()
        chip.stage(named: "Work")
        chip.remove()
        XCTAssertNil(chip.name)
    }

    // MARK: - End-to-end via NoteStore, mirroring PanelView.commitComposer

    private var tempDirectory: URL!
    private var fileURL: URL!
    private var store: NoteStore!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        fileURL = tempDirectory.appendingPathComponent("notes.json")
        store = NoteStore(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        store = nil
        tempDirectory = nil
        fileURL = nil
        super.tearDown()
    }

    /// Runs the same branch `PanelView.commitComposer` would for `.addNote`
    /// and `.sectionOnly`, using `store` and `chip` exactly as it does.
    private func commit(text: String, chip: inout ComposerSectionChip) {
        switch ComposerCommit.plan(text: text, hasAttachments: false, pendingSection: chip.name) {
        case .noop:
            break
        case .sectionOnly(let section):
            store.createSection(named: section)
            chip.remove()
        case .addNote(let section):
            if let section {
                store.createSection(named: section)
            }
            store.add(text: text, sourceApp: nil)
            chip.remove()
        }
    }

    func testCommitWithChipCreatesMissingSectionAndFilesNoteThere() {
        var chip = ComposerSectionChip()
        chip.stage(named: "Errands")

        commit(text: "buy milk", chip: &chip)

        XCTAssertEqual(store.sections, ["Errands"])
        XCTAssertEqual(store.notes.last?.text, "buy milk")
        XCTAssertEqual(store.notes.last?.listName, "Errands")
    }

    func testCommitWithChipIntoExistingSectionDoesNotDuplicateSection() {
        store.createSection(named: "Errands")
        store.setActiveSection(nil)
        var chip = ComposerSectionChip()
        chip.stage(named: "Errands")

        commit(text: "buy milk", chip: &chip)

        XCTAssertEqual(store.sections, ["Errands"])
        XCTAssertEqual(store.notes.last?.listName, "Errands")
    }

    func testChipWithEmptyTextCreatesOrSwitchesSectionWithoutAddingNote() {
        var chip = ComposerSectionChip()
        chip.stage(named: "Errands")

        commit(text: "   ", chip: &chip)

        XCTAssertEqual(store.sections, ["Errands"])
        XCTAssertEqual(store.activeSection, "Errands")
        XCTAssertTrue(store.notes.isEmpty)
    }

    func testChipClearsAfterSuccessfulCommit() {
        var chip = ComposerSectionChip()
        chip.stage(named: "Errands")

        commit(text: "buy milk", chip: &chip)

        XCTAssertNil(chip.name)
    }

    func testChipClearsAfterSectionOnlyCommit() {
        var chip = ComposerSectionChip()
        chip.stage(named: "Errands")

        commit(text: "", chip: &chip)

        XCTAssertNil(chip.name)
    }
}

import XCTest
@testable import Nickel

final class NoteStoreTests: XCTestCase {
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

    // MARK: - notesByID

    /// `notesByID` is a maintained cache, not derived on read — this checks
    /// it never drifts from `notes` across every mutation that changes the
    /// array, including one (`merge`) that mutates via subscript rather than
    /// a whole-array reassignment.
    func testNotesByIDStaysInSyncAcrossMutations() {
        func assertInSync(_ label: String, line: UInt = #line) {
            XCTAssertEqual(store.notesByID.count, store.notes.count, label, line: line)
            for note in store.notes {
                XCTAssertEqual(store.notesByID[note.id]?.id, note.id, "\(label): \(note.id)", line: line)
            }
        }

        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        assertInSync("after add")

        let idA = store.notes[0].id
        let idB = store.notes[1].id

        store.move(ids: [idA], toSection: "Work")
        assertInSync("after move")

        store.markDone(ids: [idA])
        assertInSync("after markDone")

        store.merge(ids: [idA, idB])
        assertInSync("after merge")
        let survivorID = store.notes[0].id

        store.delete(ids: [survivorID])
        assertInSync("after delete")
    }

    // MARK: - add

    func testAddCapsTextAtMaxLengthWithEllipsis() {
        let longText = String(repeating: "a", count: 25_000)
        store.add(text: longText, sourceApp: nil)

        let note = store.notes[0]
        XCTAssertEqual(note.text.count, 20_001) // 20_000-char prefix + ellipsis
        XCTAssertTrue(note.text.hasSuffix("…"))
        XCTAssertEqual(note.text.dropLast(), longText.prefix(20_000))
    }

    func testAddLandsInActiveSection() {
        store.createSection(named: "Work")
        store.add(text: "hello", sourceApp: nil)
        XCTAssertEqual(store.notes.last?.listName, "Work")
    }

    func testAddWithoutActiveSectionIsUngrouped() {
        store.add(text: "hello", sourceApp: nil)
        XCTAssertNil(store.notes.last?.listName)
    }

    func testCaptureDuplicateSuppressedWithinWindow() {
        store.add(text: "same text", sourceApp: nil, isCapture: true)
        store.add(text: "same text", sourceApp: nil, isCapture: true)
        XCTAssertEqual(store.notes.count, 1)
    }

    func testCaptureDistinctTextBothAdd() {
        store.add(text: "one", sourceApp: nil, isCapture: true)
        store.add(text: "two", sourceApp: nil, isCapture: true)
        XCTAssertEqual(store.notes.count, 2)
    }

    func testComposerPathAlwaysAdds() {
        store.add(text: "same text", sourceApp: nil, isCapture: false)
        store.add(text: "same text", sourceApp: nil, isCapture: false)
        XCTAssertEqual(store.notes.count, 2)
    }

    func testAddReportsFailedAttachmentIndices() throws {
        let sourceA = tempDirectory.appendingPathComponent("a.txt")
        try "fileA".write(to: sourceA, atomically: true, encoding: .utf8)
        let missingSource = tempDirectory.appendingPathComponent("missing.txt")

        let failedIndices = store.add(
            text: "hello",
            attachments: [
                (sourceURL: sourceA, filename: "a.txt", contentType: "public.text"),
                (sourceURL: missingSource, filename: "missing.txt", contentType: "public.text"),
            ],
            sourceApp: nil
        )

        XCTAssertEqual(failedIndices, [1])
        let note = store.notes[0]
        XCTAssertEqual(note.attachments.count, 1)
        XCTAssertEqual(note.attachments[0].filename, "a.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: note.attachments[0], in: note).path))
    }

    func testAddAllAttachmentsSucceedReturnsEmpty() throws {
        let sourceA = tempDirectory.appendingPathComponent("a.txt")
        try "fileA".write(to: sourceA, atomically: true, encoding: .utf8)

        let failedIndices = store.add(
            text: "hello",
            attachments: [(sourceURL: sourceA, filename: "a.txt", contentType: "public.text")],
            sourceApp: nil
        )

        XCTAssertEqual(failedIndices, [])
    }

    // MARK: - toggleDone

    func testToggleDoneTogglesGivenIDs() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        let idA = store.notes[0].id

        store.toggleDone(ids: [idA])

        XCTAssertTrue(store.notes[0].isDone)
        XCTAssertFalse(store.notes[1].isDone)
    }

    func testToggleDoneEmptySetIsNoOp() {
        store.add(text: "a", sourceApp: nil)
        let before = store.notes

        store.toggleDone(ids: [])

        XCTAssertEqual(store.notes, before)
    }

    // MARK: - move

    func testMoveToSection() {
        store.createSection(named: "Work")
        store.setActiveSection(nil)
        store.add(text: "a", sourceApp: nil)
        let id = store.notes[0].id

        store.move(ids: [id], toSection: "Work")

        XCTAssertEqual(store.notes[0].listName, "Work")
    }

    func testMoveToNilUngroups() {
        store.createSection(named: "Work")
        store.add(text: "a", sourceApp: nil)
        let id = store.notes[0].id

        store.move(ids: [id], toSection: nil)

        XCTAssertNil(store.notes[0].listName)
    }

    func testMoveToUnknownSectionAppendsIt() {
        store.add(text: "a", sourceApp: nil)
        let id = store.notes[0].id

        store.move(ids: [id], toSection: "Ghost")

        XCTAssertEqual(store.notes[0].listName, "Ghost")
        XCTAssertTrue(store.sections.contains("Ghost"))
    }

    // MARK: - renameSection

    func testRenameSectionPreservesOrderAndUpdatesActiveSection() {
        store.createSection(named: "A")
        store.createSection(named: "B")
        store.setActiveSection("A")

        store.renameSection(from: "A", to: "Z")

        XCTAssertEqual(store.sections, ["Z", "B"])
        XCTAssertEqual(store.activeSection, "Z")
    }

    func testRenameSectionMergesCaseInsensitively() {
        store.createSection(named: "Work")
        store.createSection(named: "Play") // active
        store.add(text: "a", sourceApp: nil) // lands in Play
        let id = store.notes[0].id

        store.renameSection(from: "Play", to: "work")

        XCTAssertEqual(store.sections, ["Work"])
        XCTAssertEqual(store.notes.first(where: { $0.id == id })?.listName, "Work")
        XCTAssertEqual(store.activeSection, "Work")
    }

    func testRenameSectionTrimsWhitespace() {
        store.createSection(named: "Work")
        store.renameSection(from: "Work", to: "  Projects  ")
        XCTAssertEqual(store.sections, ["Projects"])
    }

    func testRenameSectionToSameNameIsNoOp() {
        store.createSection(named: "Work")
        store.renameSection(from: "Work", to: "Work")
        XCTAssertEqual(store.sections, ["Work"])
    }

    func testRenameSectionToEmptyIsNoOp() {
        store.createSection(named: "Work")
        store.renameSection(from: "Work", to: "   ")
        XCTAssertEqual(store.sections, ["Work"])
    }

    func testRenameSectionCaseOnlyUpdatesCasing() {
        store.createSection(named: "work")
        store.add(text: "a", sourceApp: nil) // lands in work
        let id = store.notes[0].id

        store.renameSection(from: "work", to: "Work")

        XCTAssertEqual(store.sections, ["Work"])
        XCTAssertEqual(store.notes.first(where: { $0.id == id })?.listName, "Work")
        XCTAssertEqual(store.activeSection, "Work")
    }

    func testRenameSectionCaseOnlyWithWhitespace() {
        store.createSection(named: "work")
        store.add(text: "a", sourceApp: nil) // lands in work
        let id = store.notes[0].id

        store.renameSection(from: "work", to: "  Work  ")

        XCTAssertEqual(store.sections, ["Work"])
        XCTAssertEqual(store.notes.first(where: { $0.id == id })?.listName, "Work")
        XCTAssertEqual(store.activeSection, "Work")
    }

    func testRenameSectionFollowsArchivedNotesSoPutBackLandsInTheRenamedSection() {
        // Deliberate: the section still exists, just under a new name, so a
        // note put back from the Logbook belongs in it (see `renameSection`).
        store.createSection(named: "Work")
        store.add(text: "a", sourceApp: nil)
        let id = store.notes[0].id
        store.toggleDone(ids: [id])
        store.clearDone()

        store.renameSection(from: "Work", to: "Projects")

        XCTAssertEqual(store.notes[0].listName, "Projects")

        store.restore(ids: [id])
        XCTAssertEqual(store.notes[0].listName, "Projects", "the section is known, so nothing ungroups it")
    }

    // MARK: - dissolveSection

    func testDissolveSectionUngroupsItsNotesAndRemovesIt() {
        store.createSection(named: "Work")
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)

        store.dissolveSection("Work")

        XCTAssertTrue(store.sections.isEmpty)
        XCTAssertNil(store.activeSection)
        XCTAssertEqual(store.notes.count, 2, "dissolving keeps the notes; only the grouping goes")
        XCTAssertTrue(store.notes.allSatisfy { $0.listName == nil })
    }

    func testDissolveSectionLeavesOtherSectionsAndTheirNotesAlone() {
        store.createSection(named: "Work")
        store.add(text: "a", sourceApp: nil)
        store.createSection(named: "Home")
        store.add(text: "b", sourceApp: nil)

        store.dissolveSection("Work")

        XCTAssertEqual(store.sections, ["Home"])
        XCTAssertEqual(store.activeSection, "Home", "a different section was active, so it stays")
        XCTAssertEqual(store.notes.first(where: { $0.text == "b" })?.listName, "Home")
    }

    func testDissolveSectionKeepsTheLogbooksRecordOfWhereANoteCameFrom() {
        store.createSection(named: "Work")
        store.add(text: "a", sourceApp: nil)
        let id = store.notes[0].id
        store.toggleDone(ids: [id])
        store.clearDone()

        store.dissolveSection("Work")

        XCTAssertEqual(store.notes[0].listName, "Work", "the archived note keeps the section it was cleared from")

        // The section is gone by the time it's put back, so it comes back
        // ungrouped rather than resurrecting the section.
        store.restore(ids: [id])
        XCTAssertNil(store.notes[0].listName)
        XCTAssertTrue(store.sections.isEmpty)
    }

    func testDissolveUnknownSectionIsANoOp() {
        store.createSection(named: "Work")
        store.add(text: "a", sourceApp: nil)

        store.dissolveSection("Nope")

        XCTAssertEqual(store.sections, ["Work"])
        XCTAssertEqual(store.notes[0].listName, "Work")
    }

    // MARK: - createSection

    func testCreateSectionTrimsAndActivates() {
        store.createSection(named: "  Ideas  ")
        XCTAssertEqual(store.sections, ["Ideas"])
        XCTAssertEqual(store.activeSection, "Ideas")
    }

    func testCreateSectionCaseInsensitiveReusesExistingCasing() {
        store.createSection(named: "Ideas")
        store.setActiveSection(nil)

        store.createSection(named: "ideas")

        XCTAssertEqual(store.sections, ["Ideas"])
        XCTAssertEqual(store.activeSection, "Ideas")
    }

    // MARK: - uniqueProvisionalSectionName

    func testUniqueProvisionalSectionNameIncrementsCaseInsensitively() {
        XCTAssertEqual(store.uniqueProvisionalSectionName(), "New Section")

        store.createSection(named: "new section")
        XCTAssertEqual(store.uniqueProvisionalSectionName(), "New Section 2")

        store.createSection(named: "NEW SECTION 2")
        XCTAssertEqual(store.uniqueProvisionalSectionName(), "New Section 3")
    }

    // MARK: - clearDone

    func testClearDoneScopedToActiveSection() {
        store.createSection(named: "Work")
        store.add(text: "a", sourceApp: nil)
        let idA = store.notes[0].id
        store.setActiveSection(nil)
        store.add(text: "b", sourceApp: nil)
        let idB = store.notes[1].id

        store.toggleDone(ids: [idA, idB])
        store.setActiveSection("Work")
        store.clearDone()

        XCTAssertEqual(store.activeNotes.map(\.id), [idB])
        XCTAssertEqual(store.archivedNotes.map(\.id), [idA])
    }

    func testClearDoneGlobalWhenNoActiveSection() {
        store.createSection(named: "Work")
        store.add(text: "a", sourceApp: nil)
        store.setActiveSection(nil)
        store.add(text: "b", sourceApp: nil)
        store.toggleDone(ids: Set(store.notes.map(\.id)))

        store.clearDone()

        XCTAssertTrue(store.activeNotes.isEmpty)
        XCTAssertEqual(store.archivedNotes.count, 2)
    }

    func testClearDoneInSectionIgnoresActiveSection() {
        store.createSection(named: "Work")
        store.add(text: "a", sourceApp: nil)
        let idA = store.notes[0].id
        store.setActiveSection(nil) // Show All is active, not "Work"
        store.add(text: "b", sourceApp: nil)
        let idB = store.notes[1].id
        store.toggleDone(ids: [idA])

        store.clearDone(in: "Work")

        XCTAssertEqual(store.activeNotes.map(\.id), [idB])
        XCTAssertEqual(store.archivedNotes.map(\.id), [idA])
    }

    func testClearDoneInSectionLeavesAlreadyArchivedNotesAlone() {
        store.createSection(named: "Work")
        store.add(text: "a", sourceApp: nil)
        let idA = store.notes[0].id
        store.toggleDone(ids: [idA])
        store.clearDone(in: "Work")
        let firstStamp = store.notes[0].archivedAt

        // A second done note in the same section, cleared later: the first
        // note's original stamp must survive (the Logbook groups by the day
        // a note was cleared, so re-stamping would move it).
        store.add(text: "b", sourceApp: nil)
        let idB = store.notes[1].id
        store.toggleDone(ids: [idB])
        store.clearDone(in: "Work")

        XCTAssertEqual(store.notes[0].archivedAt, firstStamp)
        XCTAssertNotNil(store.notes[1].archivedAt)
        XCTAssertNotEqual(store.notes[1].archivedAt, firstStamp)
    }

    func testClearDoneArchivesRatherThanDeletingAndKeepsAttachments() throws {
        let source = tempDirectory.appendingPathComponent("a.txt")
        try "fileA".write(to: source, atomically: true, encoding: .utf8)
        store.add(text: "a", attachments: [(sourceURL: source, filename: "a.txt", contentType: "public.text")], sourceApp: nil)
        let note = store.notes[0]
        let noteDirectory = store.attachmentsDirectory.appendingPathComponent(note.id.uuidString, isDirectory: true)
        store.toggleDone(ids: [note.id])

        store.clearDone()

        XCTAssertEqual(store.notes.count, 1, "the note itself must survive being cleared")
        XCTAssertNotNil(store.notes[0].archivedAt)
        XCTAssertTrue(store.notes[0].isDone, "clearing doesn't change the done state")
        XCTAssertTrue(FileManager.default.fileExists(atPath: noteDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: store.notes[0].attachments[0], in: store.notes[0]).path))
    }

    func testClearDoneLeavesNotDoneNotesAlone() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        store.toggleDone(ids: [store.notes[0].id])

        store.clearDone()

        XCTAssertEqual(store.activeNotes.map(\.text), ["b"])
    }

    func testClearDoneDoesNotRestampAlreadyArchivedNotes() {
        store.add(text: "a", sourceApp: nil)
        let id = store.notes[0].id
        store.toggleDone(ids: [id])
        store.clearDone()
        let firstStamp = store.notes[0].archivedAt

        store.add(text: "b", sourceApp: nil)
        store.toggleDone(ids: [store.notes[1].id])
        store.clearDone()

        XCTAssertEqual(store.notes[0].archivedAt, firstStamp)
    }

    // MARK: - archive(ids:)

    func testArchiveStampsArchivedAtOnLiveNotesRegardlessOfDoneState() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        let idA = store.notes[0].id
        let idB = store.notes[1].id
        store.toggleDone(ids: [idA]) // a is done, b isn't

        store.archive(ids: [idA, idB])

        XCTAssertNotNil(store.notes[0].archivedAt)
        XCTAssertNotNil(store.notes[1].archivedAt)
        XCTAssertTrue(store.activeNotes.isEmpty)
        XCTAssertEqual(Set(store.archivedNotes.map(\.id)), [idA, idB])
    }

    func testArchiveSkipsAlreadyArchivedNotesLeavingTheirTimestampUnchanged() {
        store.add(text: "a", sourceApp: nil)
        let id = store.notes[0].id
        store.archive(ids: [id])
        let firstStamp = store.notes[0].archivedAt

        store.archive(ids: [id])

        XCTAssertEqual(store.notes[0].archivedAt, firstStamp)
    }

    func testArchiveIsNoOpForEmptyIDs() {
        store.add(text: "a", sourceApp: nil)

        store.archive(ids: [])

        XCTAssertNil(store.notes[0].archivedAt)
    }

    func testArchiveIsNoOpForUnknownIDs() {
        store.add(text: "a", sourceApp: nil)

        store.archive(ids: [UUID()])

        XCTAssertNil(store.notes[0].archivedAt)
    }

    // MARK: - Logbook (restore / delete permanently / completedAt)

    func testActiveNotesExcludeArchivedAndArchivedAreNewestFirst() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        store.add(text: "c", sourceApp: nil)
        let idA = store.notes[0].id
        let idB = store.notes[1].id

        store.toggleDone(ids: [idA])
        store.clearDone()
        store.toggleDone(ids: [idB])
        store.clearDone()

        XCTAssertEqual(store.activeNotes.map(\.text), ["c"])
        XCTAssertEqual(store.archivedNotes.map(\.text), ["b", "a"])
    }

    func testArchivedNotesClearedInOneBatchAreOrderedNewestCreatedFirst() {
        // A batch clear stamps every note with the same `archivedAt`, so the
        // order has to come from `createdAt` rather than from `sorted`'s
        // (unspecified) stability.
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        store.add(text: "c", sourceApp: nil)
        store.toggleDone(ids: Set(store.notes.map(\.id)))

        store.clearDone()

        let stamps = Set(store.archivedNotes.compactMap(\.archivedAt))
        XCTAssertEqual(stamps.count, 1, "a batch clear shares one stamp — that's what makes the tiebreak matter")
        XCTAssertEqual(store.archivedNotes.map(\.text), ["c", "b", "a"])
    }

    func testRestoreClearsArchivedAtAndKeepsDoneState() {
        store.createSection(named: "Work")
        store.add(text: "a", sourceApp: nil)
        let id = store.notes[0].id
        store.toggleDone(ids: [id])
        store.clearDone()

        store.restore(ids: [id])

        XCTAssertNil(store.notes[0].archivedAt)
        XCTAssertTrue(store.notes[0].isDone)
        XCTAssertEqual(store.notes[0].listName, "Work")
        XCTAssertEqual(store.activeNotes.map(\.id), [id])
        XCTAssertTrue(store.archivedNotes.isEmpty)
    }

    func testRestoreUngroupsNoteWhoseSectionIsGone() {
        store.createSection(named: "Work")
        store.add(text: "a", sourceApp: nil)
        let id = store.notes[0].id
        store.toggleDone(ids: [id])
        store.clearDone()
        store.deleteSection("Work") // the archived note is the only one left in it

        store.restore(ids: [id])

        XCTAssertNil(store.notes.first(where: { $0.id == id })?.listName)
    }

    func testDeletePermanentlyRemovesNoteAndAttachmentsDirectory() throws {
        store.add(text: "a", sourceApp: nil)
        let id = store.notes[0].id
        let noteDirectory = store.attachmentsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: noteDirectory, withIntermediateDirectories: true)
        try "dummy".write(to: noteDirectory.appendingPathComponent("dummy.txt"), atomically: true, encoding: .utf8)
        store.toggleDone(ids: [id])
        store.clearDone()

        store.deletePermanently(ids: [id])

        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: noteDirectory.path))
    }

    // MARK: - archiveSection

    func testArchiveSectionArchivesLiveNotesRemovesSectionAndKeepsAttachments() throws {
        let source = tempDirectory.appendingPathComponent("a.txt")
        try "fileA".write(to: source, atomically: true, encoding: .utf8)
        store.createSection(named: "Work")
        store.add(text: "a", attachments: [(sourceURL: source, filename: "a.txt", contentType: "public.text")], sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        let idA = store.notes[0].id
        let idB = store.notes[1].id
        let noteDirectory = store.attachmentsDirectory.appendingPathComponent(idA.uuidString, isDirectory: true)

        store.archiveSection("Work")

        XCTAssertEqual(store.notes.count, 2, "notes survive; they move to the Logbook, not deleted")
        XCTAssertNotNil(store.notes.first(where: { $0.id == idA })?.archivedAt)
        XCTAssertNotNil(store.notes.first(where: { $0.id == idB })?.archivedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: noteDirectory.path), "attachments are untouched by archiving")
        XCTAssertFalse(store.sections.contains("Work"))
    }

    func testArchiveSectionResetsActiveSectionWhenItWasActive() {
        store.createSection(named: "Work")
        store.setActiveSection("Work")

        store.archiveSection("Work")

        XCTAssertNil(store.activeSection)
    }

    func testArchiveSectionLeavesAlreadyArchivedNotesUntouched() {
        store.createSection(named: "Work")
        store.add(text: "a", sourceApp: nil)
        let id = store.notes[0].id
        store.toggleDone(ids: [id])
        store.clearDone()
        let originalArchivedAt = store.notes[0].archivedAt

        store.archiveSection("Work")

        XCTAssertEqual(store.notes[0].archivedAt, originalArchivedAt, "a note already in the Logbook keeps its original archive timestamp")
    }

    func testArchiveSectionIsNoOpForUnknownName() {
        store.createSection(named: "Work")
        store.add(text: "a", sourceApp: nil)

        store.archiveSection("Nonexistent")

        XCTAssertNil(store.notes[0].archivedAt)
        XCTAssertTrue(store.sections.contains("Work"))
    }

    func testRestoreUngroupsNoteArchivedByArchiveSection() {
        store.createSection(named: "Work")
        store.add(text: "a", sourceApp: nil)
        let id = store.notes[0].id

        store.archiveSection("Work")
        store.restore(ids: [id])

        XCTAssertNil(store.notes.first(where: { $0.id == id })?.listName)
        XCTAssertNil(store.notes.first(where: { $0.id == id })?.archivedAt)
    }

    func testToggleDoneStampsAndClearsCompletedAt() {
        store.add(text: "a", sourceApp: nil)
        let id = store.notes[0].id
        XCTAssertNil(store.notes[0].completedAt)

        store.toggleDone(ids: [id])
        XCTAssertNotNil(store.notes[0].completedAt)

        store.toggleDone(ids: [id])
        XCTAssertNil(store.notes[0].completedAt)
    }

    // MARK: - delete

    func testDeleteRemovesNotesAndAttachmentsDirectory() throws {
        store.add(text: "a", sourceApp: nil)
        let id = store.notes[0].id
        let noteDir = store.attachmentsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: noteDir, withIntermediateDirectories: true)
        try "dummy".write(to: noteDir.appendingPathComponent("dummy.txt"), atomically: true, encoding: .utf8)

        store.delete(ids: [id])

        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: noteDir.path))
    }

    // MARK: - merge

    func testMergeKeepsEarliestSurvivorJoinsTextAndMovesAttachments() throws {
        let sourceA = tempDirectory.appendingPathComponent("a.txt")
        let sourceB = tempDirectory.appendingPathComponent("b.txt")
        try "fileA".write(to: sourceA, atomically: true, encoding: .utf8)
        try "fileB".write(to: sourceB, atomically: true, encoding: .utf8)

        store.add(text: "first", attachments: [(sourceURL: sourceA, filename: "a.txt", contentType: "public.text")], sourceApp: nil)
        let firstID = store.notes[0].id
        store.add(text: "second", attachments: [(sourceURL: sourceB, filename: "b.txt", contentType: "public.text")], sourceApp: nil)
        let secondID = store.notes[1].id

        store.merge(ids: [firstID, secondID])

        XCTAssertEqual(store.notes.count, 1)
        let survivor = store.notes[0]
        XCTAssertEqual(survivor.id, firstID) // earliest-created note survives
        XCTAssertEqual(survivor.text, "first\n\nsecond")
        XCTAssertEqual(survivor.attachments.count, 2)

        // Donor's attachment file physically moved into the survivor's directory.
        for attachment in survivor.attachments {
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: attachment, in: survivor).path))
        }
        let donorDir = store.attachmentsDirectory.appendingPathComponent(secondID.uuidString, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: donorDir.path))
    }

    func testMergeSkipsRecordsForUnmovableAttachments() throws {
        let sourceA = tempDirectory.appendingPathComponent("a.txt")
        let sourceB = tempDirectory.appendingPathComponent("b.txt")
        try "fileA".write(to: sourceA, atomically: true, encoding: .utf8)
        try "fileB".write(to: sourceB, atomically: true, encoding: .utf8)

        store.add(text: "first", attachments: [(sourceURL: sourceA, filename: "a.txt", contentType: "public.text")], sourceApp: nil)
        let firstID = store.notes[0].id
        store.add(text: "second", attachments: [(sourceURL: sourceB, filename: "b.txt", contentType: "public.text")], sourceApp: nil)
        let secondID = store.notes[1].id
        let donorAttachment = store.notes[1].attachments[0]

        // Delete the donor's file on disk before merging, so moveItem fails.
        let donorFileURL = store.url(for: donorAttachment, in: store.notes[1])
        try FileManager.default.removeItem(at: donorFileURL)

        store.merge(ids: [firstID, secondID])

        XCTAssertEqual(store.notes.count, 1) // merge still happened
        let survivor = store.notes[0]
        XCTAssertEqual(survivor.text, "first\n\nsecond")
        XCTAssertFalse(survivor.attachments.contains(where: { $0.id == donorAttachment.id }))
    }

    func testMergeLeavesDonorDirectoryWhenAMoveFails() throws {
        let sourceA = tempDirectory.appendingPathComponent("a.txt")
        let sourceB = tempDirectory.appendingPathComponent("b.txt")
        try "fileA".write(to: sourceA, atomically: true, encoding: .utf8)
        try "fileB".write(to: sourceB, atomically: true, encoding: .utf8)

        store.add(text: "first", attachments: [(sourceURL: sourceA, filename: "a.txt", contentType: "public.text")], sourceApp: nil)
        let firstID = store.notes[0].id
        store.add(text: "second", attachments: [(sourceURL: sourceB, filename: "b.txt", contentType: "public.text")], sourceApp: nil)
        let secondID = store.notes[1].id
        let donorAttachment = store.notes[1].attachments[0]

        // Pre-create a collision at the destination path so moveItem throws.
        let destinationDir = store.attachmentsDirectory.appendingPathComponent(firstID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let collisionURL = destinationDir.appendingPathComponent("\(donorAttachment.id.uuidString)-b.txt")
        try "collision".write(to: collisionURL, atomically: true, encoding: .utf8)

        store.merge(ids: [firstID, secondID])

        let survivor = store.notes[0]
        XCTAssertFalse(survivor.attachments.contains(where: { $0.id == donorAttachment.id }))

        let donorDir = store.attachmentsDirectory.appendingPathComponent(secondID.uuidString, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: donorDir.path), "donor directory should be left in place when a move fails")
        let donorFileURL = donorDir.appendingPathComponent("\(donorAttachment.id.uuidString)-b.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: donorFileURL.path), "donor's file should still be present since it never moved")
    }

    func testMergeJoinsTextInVisibleOrderNotCreationOrder() {
        store.add(text: "first", sourceApp: nil)
        let firstID = store.notes[0].id
        store.add(text: "second", sourceApp: nil)
        let secondID = store.notes[1].id
        store.add(text: "third", sourceApp: nil)
        let thirdID = store.notes[2].id

        // Drag "third" to the front: array order is now third, first, second,
        // while creation order (first, second, third) is unchanged.
        store.move(ids: [thirdID], toSection: nil, before: firstID)
        XCTAssertEqual(store.notes.map(\.id), [thirdID, firstID, secondID])

        store.merge(ids: [firstID, secondID, thirdID])

        XCTAssertEqual(store.notes.count, 1)
        let survivor = store.notes[0]
        XCTAssertEqual(survivor.id, firstID) // earliest-created note still survives
        XCTAssertEqual(survivor.text, "third\n\nfirst\n\nsecond") // joined in visible (array) order
    }

    func testMergeAppendsDonorAttachmentsInVisibleOrder() throws {
        let sourceA = tempDirectory.appendingPathComponent("a.txt")
        let sourceB = tempDirectory.appendingPathComponent("b.txt")
        try "fileA".write(to: sourceA, atomically: true, encoding: .utf8)
        try "fileB".write(to: sourceB, atomically: true, encoding: .utf8)

        store.add(text: "first", sourceApp: nil)
        let firstID = store.notes[0].id
        store.add(text: "second", attachments: [(sourceURL: sourceA, filename: "a.txt", contentType: "public.text")], sourceApp: nil)
        let secondID = store.notes[1].id
        store.add(text: "third", attachments: [(sourceURL: sourceB, filename: "b.txt", contentType: "public.text")], sourceApp: nil)
        let thirdID = store.notes[2].id

        // Drag "third" before "second": array order is first, third, second,
        // so third's attachment should be appended before second's.
        store.move(ids: [thirdID], toSection: nil, before: secondID)
        XCTAssertEqual(store.notes.map(\.id), [firstID, thirdID, secondID])

        store.merge(ids: [firstID, secondID, thirdID])

        let survivor = store.notes[0]
        XCTAssertEqual(survivor.id, firstID)
        XCTAssertEqual(survivor.attachments.count, 2)
        XCTAssertEqual(survivor.attachments[0].filename, "b.txt")
        XCTAssertEqual(survivor.attachments[1].filename, "a.txt")
    }

    // MARK: - Persistence

    func testPersistenceRoundTrips() {
        store.createSection(named: "Work")
        store.add(text: "hello", sourceApp: "TestApp")
        store.createSection(named: "Play")
        store.setActiveSection("Play")
        store.saveNow()

        let reloaded = NoteStore(fileURL: fileURL)

        XCTAssertEqual(reloaded.notes.map(\.text), store.notes.map(\.text))
        XCTAssertEqual(reloaded.sections, store.sections)
        XCTAssertEqual(reloaded.activeSection, store.activeSection)
    }

    func testSaveAppliesOwnerOnlyPermissions() {
        store.add(text: "x", sourceApp: nil)
        store.saveNow()

        let fileAttributes = try! FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.uint16Value, 0o600)

        let directoryAttributes = try! FileManager.default.attributesOfItem(atPath: tempDirectory.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.uint16Value, 0o700)
    }

    func testScheduledSaveEventuallyWritesFile() {
        store.add(text: "background save", sourceApp: "TestApp")

        let deadline = Date().addingTimeInterval(2)
        var didFindNote = false
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let reloaded = NoteStore(fileURL: fileURL)
                if reloaded.notes.map(\.text).contains("background save") {
                    didFindNote = true
                    break
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertTrue(didFindNote, "expected the debounced save to eventually write the note to disk")
    }

    // MARK: - nextSaveDelay

    func testNextSaveDelayWithNoPendingSaveUsesDebounce() {
        let delay = NoteStore.nextSaveDelay(firstPendingAt: nil, now: Date(), debounce: 0.5, maxDeferral: 3.0)
        XCTAssertEqual(delay, 0.5, accuracy: 0.001)
    }

    func testNextSaveDelayBelowCeilingUsesFullDebounce() {
        let now = Date()
        let firstPendingAt = now.addingTimeInterval(-0.1)
        let delay = NoteStore.nextSaveDelay(firstPendingAt: firstPendingAt, now: now, debounce: 0.5, maxDeferral: 3.0)
        XCTAssertEqual(delay, 0.5, accuracy: 0.001)
    }

    func testNextSaveDelayNearCeilingIsShortened() {
        let now = Date()
        let firstPendingAt = now.addingTimeInterval(-2.8)
        let delay = NoteStore.nextSaveDelay(firstPendingAt: firstPendingAt, now: now, debounce: 0.5, maxDeferral: 3.0)
        XCTAssertEqual(delay, 0.2, accuracy: 0.001)
    }

    func testNextSaveDelayPastCeilingIsNeverNegative() {
        let now = Date()
        let firstPendingAt = now.addingTimeInterval(-3.5)
        let delay = NoteStore.nextSaveDelay(firstPendingAt: firstPendingAt, now: now, debounce: 0.5, maxDeferral: 3.0)
        XCTAssertEqual(delay, 0, accuracy: 0.001)
    }

    // MARK: - bounded deferral integration

    func testContinuousMutationsStillHitDiskWithinCeiling() {
        store.add(text: "burst", sourceApp: nil)
        let noteID = store.notes.first!.id
        let start = Date()

        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [store] _ in
            store?.update(id: noteID, text: "burst \(Date().timeIntervalSince1970)")
        }
        defer { timer.invalidate() }

        let deadline = start.addingTimeInterval(4.0)
        var didFindWrite = false
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                didFindWrite = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTAssertTrue(didFindWrite, "expected a write to land within the deferral ceiling despite continuous mutations")
        XCTAssertLessThan(Date().timeIntervalSince(start), 4.0, "write should have landed before the 4.0s bound")
    }

    func testFailedWriteSetsSaveError() throws {
        let readonlyDirectory = tempDirectory.appendingPathComponent("readonly", isDirectory: true)
        try FileManager.default.createDirectory(at: readonlyDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readonlyDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readonlyDirectory.path)
        }

        let failingFileURL = readonlyDirectory.appendingPathComponent("sub/notes.json")
        let failingStore = NoteStore(fileURL: failingFileURL)
        failingStore.add(text: "should fail to save", sourceApp: nil)
        failingStore.saveNow()

        let exp = expectation(description: "main queue drained")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 2)

        XCTAssertNotNil(failingStore.saveError)
    }

    func testSuccessfulWriteClearsSaveError() throws {
        let readonlyDirectory = tempDirectory.appendingPathComponent("readonly2", isDirectory: true)
        try FileManager.default.createDirectory(at: readonlyDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readonlyDirectory.path)

        let failingFileURL = readonlyDirectory.appendingPathComponent("sub/notes.json")
        let failingStore = NoteStore(fileURL: failingFileURL)
        failingStore.add(text: "should fail then succeed", sourceApp: nil)
        failingStore.saveNow()

        let exp1 = expectation(description: "main queue drained after failure")
        DispatchQueue.main.async { exp1.fulfill() }
        wait(for: [exp1], timeout: 2)
        XCTAssertNotNil(failingStore.saveError, "precondition: save should have failed")

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readonlyDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readonlyDirectory.path)
        }
        failingStore.saveNow()

        let exp2 = expectation(description: "main queue drained after success")
        DispatchQueue.main.async { exp2.fulfill() }
        wait(for: [exp2], timeout: 2)

        XCTAssertNil(failingStore.saveError)
    }

    func testDecodingNoteWithoutAttachmentsKeyIsBackwardCompatible() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "text": "legacy note",
          "listName": null,
          "isDone": false,
          "createdAt": "2024-01-01T00:00:00Z",
          "sourceApp": null
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let note = try decoder.decode(Note.self, from: json)

        XCTAssertEqual(note.text, "legacy note")
        XCTAssertTrue(note.attachments.isEmpty)
        XCTAssertNil(note.archivedAt)
        XCTAssertNil(note.completedAt)
    }

    func testArchivedAndCompletedStampsRoundTrip() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        let idA = store.notes[0].id
        store.toggleDone(ids: [idA])
        store.clearDone()
        store.saveNow()

        let reloaded = NoteStore(fileURL: fileURL)

        XCTAssertEqual(reloaded.notes.count, 2)
        XCTAssertEqual(reloaded.archivedNotes.map(\.id), [idA])
        // ISO-8601 encoding drops sub-second precision, so these compare
        // to the whole second, like every other date the store persists.
        XCTAssertEqual(
            reloaded.notes[0].archivedAt?.timeIntervalSinceReferenceDate ?? 0,
            store.notes[0].archivedAt?.timeIntervalSinceReferenceDate ?? 0,
            accuracy: 1.0
        )
        XCTAssertEqual(
            reloaded.notes[0].completedAt?.timeIntervalSinceReferenceDate ?? 0,
            store.notes[0].completedAt?.timeIntervalSinceReferenceDate ?? 0,
            accuracy: 1.0
        )
        XCTAssertNil(reloaded.notes[1].archivedAt)
        XCTAssertNil(reloaded.notes[1].completedAt)
    }

    func testArchivedNoteDoesNotResurrectItsDeletedSectionOnLoad() {
        store.createSection(named: "Work")
        store.add(text: "a", sourceApp: nil)
        store.toggleDone(ids: [store.notes[0].id])
        store.clearDone()
        store.deleteSection("Work")
        store.saveNow()

        let reloaded = NoteStore(fileURL: fileURL)

        XCTAssertEqual(reloaded.notes.count, 1, "the archived note survives its section being deleted")
        XCTAssertTrue(reloaded.sections.isEmpty)
    }

    // MARK: - Corruption recovery

    /// Finds corrupt-file backups (`notes-corrupt-*.json`) in `tempDirectory`.
    private func corruptBackupFiles() -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.lastPathComponent.hasPrefix("notes-corrupt-") && $0.pathExtension == "json" }
    }

    func testCorruptFileIsMovedAsideAndStoreStartsEmpty() {
        try! Data([0xFF, 0x00, 0x12]).write(to: fileURL)

        let reloaded = NoteStore(fileURL: fileURL)

        XCTAssertTrue(reloaded.notes.isEmpty)
        XCTAssertTrue(reloaded.sections.isEmpty)
        XCTAssertEqual(corruptBackupFiles().count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testSecondCorruptLoadDoesNotDestroyFirstBackup() {
        let firstGarbage = "first garbage".data(using: .utf8)!
        try! firstGarbage.write(to: fileURL)
        _ = NoteStore(fileURL: fileURL)

        let secondGarbage = "second different garbage".data(using: .utf8)!
        try! secondGarbage.write(to: fileURL)
        _ = NoteStore(fileURL: fileURL)

        let backups = corruptBackupFiles()
        XCTAssertEqual(backups.count, 2)
        let contents = Set(backups.map { try! Data(contentsOf: $0) })
        XCTAssertEqual(contents, Set([firstGarbage, secondGarbage]))
    }

    func testUnparseableJSONObjectIsTreatedAsCorrupt() {
        try! "[1, 2, 3]".data(using: .utf8)!.write(to: fileURL)

        let reloaded = NoteStore(fileURL: fileURL)

        XCTAssertTrue(reloaded.notes.isEmpty)
        XCTAssertTrue(reloaded.sections.isEmpty)
        XCTAssertEqual(corruptBackupFiles().count, 1)
    }

    // MARK: - Legacy migration and repair

    func testLegacyBareArrayMigratesSectionsInFirstAppearanceOrder() {
        let json = """
        [
          {
            "id": "\(UUID().uuidString)",
            "text": "note in B",
            "listName": "B",
            "isDone": false,
            "createdAt": "2024-01-01T00:00:00Z",
            "sourceApp": null
          },
          {
            "id": "\(UUID().uuidString)",
            "text": "note in A",
            "listName": "A",
            "isDone": false,
            "createdAt": "2024-01-02T00:00:00Z",
            "sourceApp": null
          }
        ]
        """
        try! json.data(using: .utf8)!.write(to: fileURL)

        let reloaded = NoteStore(fileURL: fileURL)

        XCTAssertEqual(reloaded.sections, ["B", "A"])
        XCTAssertNil(reloaded.activeSection)
        XCTAssertEqual(reloaded.notes.map(\.text), ["note in B", "note in A"])
    }

    func testEnvelopeWithUnknownActiveSectionResetsToNil() {
        let json = """
        {
          "version": 2,
          "sections": ["Work"],
          "activeSection": "Ghost",
          "notes": []
        }
        """
        try! json.data(using: .utf8)!.write(to: fileURL)

        let reloaded = NoteStore(fileURL: fileURL)

        XCTAssertEqual(reloaded.sections, ["Work"])
        XCTAssertNil(reloaded.activeSection)
    }

    func testEnvelopeWithNoteInUnlistedSectionAppendsSection() {
        let json = """
        {
          "version": 2,
          "sections": ["Work"],
          "activeSection": null,
          "notes": [
            {
              "id": "\(UUID().uuidString)",
              "text": "orphaned note",
              "listName": "Personal",
              "isDone": false,
              "createdAt": "2024-01-01T00:00:00Z",
              "sourceApp": null
            }
          ]
        }
        """
        try! json.data(using: .utf8)!.write(to: fileURL)

        let reloaded = NoteStore(fileURL: fileURL)

        XCTAssertEqual(reloaded.sections, ["Work", "Personal"])
        XCTAssertNil(reloaded.activeSection)
    }

    // MARK: - Orphaned attachment sweep

    func testSweepRemovesOrphanedAttachmentDirectoryOnCleanLoad() throws {
        store.add(text: "hello", sourceApp: nil)
        let noteID = store.notes[0].id
        store.saveNow()

        let noteDir = store.attachmentsDirectory.appendingPathComponent(noteID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: noteDir, withIntermediateDirectories: true)
        try "dummy".write(to: noteDir.appendingPathComponent("dummy.txt"), atomically: true, encoding: .utf8)

        let orphanID = UUID()
        let orphanDir = store.attachmentsDirectory.appendingPathComponent(orphanID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)
        try "dummy".write(to: orphanDir.appendingPathComponent("dummy.txt"), atomically: true, encoding: .utf8)

        _ = NoteStore(fileURL: fileURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: noteDir.path))
    }

    func testSweepSkippedWhenStoreFileIsCorrupt() throws {
        try "not json".data(using: .utf8)!.write(to: fileURL)

        let orphanID = UUID()
        let orphanDir = store.attachmentsDirectory.appendingPathComponent(orphanID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)
        try "dummy".write(to: orphanDir.appendingPathComponent("dummy.txt"), atomically: true, encoding: .utf8)

        let reloaded = NoteStore(fileURL: fileURL)

        XCTAssertTrue(reloaded.notes.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanDir.path))
    }
}

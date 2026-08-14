import AppKit
import XCTest
@testable import Nickel

final class PanelActionsTests: XCTestCase {
    private var tempDirectory: URL!
    private var fileURL: URL!
    private var store: NoteStore!
    private var selection: SelectionModel!
    private var actions: PanelActions!

    private let markDoneOnCopyDefaultsKey = "markDoneOnCopy"

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        fileURL = tempDirectory.appendingPathComponent("notes.json")
        store = NoteStore(fileURL: fileURL)
        selection = SelectionModel(store: store)
        actions = PanelActions(store: store, selection: selection)
        UserDefaults.standard.removeObject(forKey: markDoneOnCopyDefaultsKey)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        UserDefaults.standard.removeObject(forKey: markDoneOnCopyDefaultsKey)
        actions = nil
        selection = nil
        store = nil
        tempDirectory = nil
        fileURL = nil
        super.tearDown()
    }

    // MARK: - delete

    func testDeleteMiddleNoteSelectsFollowingNote() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        store.add(text: "c", sourceApp: nil)
        let ids = store.notes.map(\.id)

        selection.selectSingle(ids[1])
        actions.delete()

        XCTAssertEqual(store.notes.map(\.id), [ids[0], ids[2]])
        XCTAssertEqual(selection.selectedIDs, [ids[2]])
    }

    func testDeleteLastNoteSelectsNewLastSurvivor() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        store.add(text: "c", sourceApp: nil)
        let ids = store.notes.map(\.id)

        selection.selectSingle(ids[2])
        actions.delete()

        XCTAssertEqual(store.notes.map(\.id), [ids[0], ids[1]])
        XCTAssertEqual(selection.selectedIDs, [ids[1]])
    }

    func testDeleteEverythingClearsSelection() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        let ids = store.notes.map(\.id)

        selection.selectedIDs = Set(ids)
        actions.delete()

        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertTrue(selection.selectedIDs.isEmpty)
    }

    func testDeleteNonContiguousMultiSelectionSelectsSurvivorAfterLastDeletedIndex() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        store.add(text: "c", sourceApp: nil)
        store.add(text: "d", sourceApp: nil)
        store.add(text: "e", sourceApp: nil)
        let ids = store.notes.map(\.id)

        // Delete indices 0 and 3 (non-contiguous); the last deleted index is
        // 3, so the next selection should be the survivor after index 3: ids[4].
        selection.selectedIDs = [ids[0], ids[3]]
        actions.delete()

        XCTAssertEqual(store.notes.map(\.id), [ids[1], ids[2], ids[4]])
        XCTAssertEqual(selection.selectedIDs, [ids[4]])
    }

    func testDeleteWithNoSurvivorAfterLastDeletedSelectsPrecedingSurvivor() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        store.add(text: "c", sourceApp: nil)
        let ids = store.notes.map(\.id)

        // Delete indices 1 and 2 (the tail); nothing survives after index 2,
        // so selection should fall back to the last survivor before index 1.
        selection.selectedIDs = [ids[1], ids[2]]
        actions.delete()

        XCTAssertEqual(store.notes.map(\.id), [ids[0]])
        XCTAssertEqual(selection.selectedIDs, [ids[0]])
    }

    // MARK: - moveToLogbook

    func testMoveToLogbookArchivesSelectionAndPrunesItFromTheList() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        let ids = store.notes.map(\.id)

        selection.selectedIDs = [ids[0]]
        actions.moveToLogbook()

        XCTAssertEqual(store.activeNotes.map(\.id), [ids[1]])
        XCTAssertEqual(store.archivedNotes.map(\.id), [ids[0]])
        XCTAssertTrue(selection.selectedIDs.isEmpty, "the archived note is no longer visible, so selection pruning must drop it")
    }

    func testMoveToLogbookWorksRegardlessOfDoneState() {
        store.add(text: "a", sourceApp: nil)
        let id = store.notes[0].id

        selection.selectedIDs = [id]
        actions.moveToLogbook()

        XCTAssertNotNil(store.notes[0].archivedAt)
    }

    func testMoveToLogbookIsNoOpWhenLogbookIsShowing() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        let ids = store.notes.map(\.id)
        store.archive(ids: [ids[0]])
        selection.setShowingLogbook(true)
        // Selecting both the already-archived note and the still-live one
        // directly (bypassing the click flow that would normally scope
        // selection to what's on screen) so a wrongly-unguarded
        // `moveToLogbook()` would have something live to (wrongly) archive.
        selection.selectedIDs = [ids[0], ids[1]]

        actions.moveToLogbook()

        // Still live: had this gone through, `archive(ids:)` would have
        // stamped it too.
        XCTAssertNil(store.notes.first(where: { $0.id == ids[1] })?.archivedAt)
        XCTAssertEqual(selection.selectedIDs, [ids[0], ids[1]], "no-op: selection in the Logbook is untouched")
    }

    // MARK: - merge

    func testMergeKeepsEarliestCreatedNoteAndSelectsIt() {
        store.add(text: "first", sourceApp: nil)
        let idFirst = store.notes[0].id
        store.add(text: "second", sourceApp: nil)
        let idSecond = store.notes[1].id

        selection.selectedIDs = [idFirst, idSecond]
        actions.merge()

        XCTAssertEqual(store.notes.map(\.id), [idFirst])
        XCTAssertEqual(selection.selectedIDs, [idFirst])
    }

    func testMergeWithFewerThanTwoSelectedIsNoOp() {
        store.add(text: "first", sourceApp: nil)
        let idFirst = store.notes[0].id

        selection.selectedIDs = [idFirst]
        actions.merge()

        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(selection.selectedIDs, [idFirst])
    }

    // MARK: - commitActiveEditIfAny

    func testCommitActiveEditWritesBufferAndClearsEditingState() {
        store.add(text: "original", sourceApp: nil)
        let id = store.notes[0].id

        selection.beginEditing(id: id, text: "edited text")
        actions.commitActiveEditIfAny()

        XCTAssertEqual(store.notes[0].text, "edited text")
        XCTAssertNil(selection.editingID)
        XCTAssertEqual(selection.editingText, "")
    }

    func testCommitActiveEditWithNoActiveEditIsNoOp() {
        store.add(text: "original", sourceApp: nil)

        actions.commitActiveEditIfAny()

        XCTAssertEqual(store.notes[0].text, "original")
        XCTAssertNil(selection.editingID)
    }

    // MARK: - editInNewWindow

    /// The posted note ids, collected while `body` runs.
    private func requestedEditorNoteIDs(during body: () -> Void) -> [UUID] {
        var posted: [UUID] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .nickelEditNoteInNewWindow,
            object: nil,
            queue: nil
        ) { notification in
            if let id = notification.object as? UUID { posted.append(id) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        body()
        return posted
    }

    func testEditInNewWindowRequestsTheSingleSelectedNote() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        let ids = store.notes.map(\.id)
        selection.selectSingle(ids[1])

        XCTAssertEqual(requestedEditorNoteIDs { actions.editInNewWindow() }, [ids[1]])
    }

    func testEditInNewWindowIgnoresMultiSelection() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        selection.selectedIDs = Set(store.notes.map(\.id))

        XCTAssertTrue(requestedEditorNoteIDs { actions.editInNewWindow() }.isEmpty)
    }

    func testEditInNewWindowIgnoresEmptySelection() {
        store.add(text: "a", sourceApp: nil)

        XCTAssertTrue(requestedEditorNoteIDs { actions.editInNewWindow() }.isEmpty)
    }

    func testEditInNewWindowCommitsAnInProgressInlineEditFirst() {
        store.add(text: "original", sourceApp: nil)
        let id = store.notes[0].id
        selection.selectSingle(id)
        selection.beginEditing(id: id, text: "edited text")

        XCTAssertEqual(requestedEditorNoteIDs { actions.editInNewWindow() }, [id])
        XCTAssertEqual(store.notes[0].text, "edited text")
        XCTAssertNil(selection.editingID)
    }

    // MARK: - toggleDone

    func testToggleDoneTogglesExactlyTheSelection() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        let ids = store.notes.map(\.id)

        selection.selectedIDs = [ids[0]]
        actions.toggleDone()

        XCTAssertTrue(store.notes[0].isDone)
        XCTAssertFalse(store.notes[1].isDone)
    }

    // MARK: - allSelectedAreDone

    func testAllSelectedAreDoneIsFalseWhenSelectionIsEmpty() {
        store.add(text: "a", sourceApp: nil)

        XCTAssertFalse(actions.allSelectedAreDone)
    }

    func testAllSelectedAreDoneIsFalseWhenSelectionIsMixed() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        let ids = store.notes.map(\.id)
        store.toggleDone(ids: [ids[0]])

        selection.selectedIDs = Set(ids)

        XCTAssertFalse(actions.allSelectedAreDone)
    }

    func testAllSelectedAreDoneIsTrueWhenAllSelectedAreDone() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        let ids = store.notes.map(\.id)
        store.toggleDone(ids: Set(ids))

        selection.selectedIDs = Set(ids)

        XCTAssertTrue(actions.allSelectedAreDone)
    }

    // MARK: - Logbook

    /// Archives the single note in the store and opens the Logbook with it
    /// selected — the state every check below starts from.
    private func archiveSingleNoteAndShowLogbook() -> UUID {
        let id = store.notes[0].id
        store.toggleDone(ids: [id])
        store.clearDone()
        selection.setShowingLogbook(true)
        selection.selectSingle(id)
        return id
    }

    func testLogbookDeleteAsksBeforeDeletingPermanently() {
        store.add(text: "a", sourceApp: nil)
        let id = archiveSingleNoteAndShowLogbook()

        actions.delete()

        XCTAssertEqual(selection.permanentDeleteConfirmation, [id])
        XCTAssertEqual(store.notes.count, 1, "nothing is deleted until the dialog is confirmed")

        actions.confirmPermanentDelete()

        XCTAssertNil(selection.permanentDeleteConfirmation)
        XCTAssertTrue(store.notes.isEmpty)
    }

    func testLogbookRowsAreReadOnly() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        store.toggleDone(ids: Set(store.notes.map(\.id)))
        store.clearDone()
        selection.setShowingLogbook(true)
        selection.selectedIDs = Set(store.notes.map(\.id))

        actions.toggleDone()
        actions.startEditingIfSingleSelected()
        actions.merge()
        actions.move(toSection: "Work")

        XCTAssertTrue(store.notes.allSatisfy(\.isDone))
        XCTAssertNil(selection.editingID)
        XCTAssertEqual(store.notes.count, 2)
        XCTAssertTrue(store.notes.allSatisfy { $0.listName == nil })
    }

    func testCopyingInTheLogbookPutsTheArchivedNoteOnThePasteboard() {
        store.add(text: "archived note", sourceApp: nil)
        _ = archiveSingleNoteAndShowLogbook()

        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        actions.copy(pasteboard: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "archived note")
    }

    func testCopyAllAsListInTheLogbookCopiesEveryVisibleArchivedNote() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        store.toggleDone(ids: Set(store.notes.map(\.id)))
        store.clearDone()
        selection.setShowingLogbook(true)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        actions.copyAllAsList(pasteboard: pasteboard)

        let copied = pasteboard.string(forType: .string)
        XCTAssertEqual(copied?.contains("1. b"), true)
        XCTAssertEqual(copied?.contains("2. a"), true)
    }

    func testToggleExpandedIsANoOpInTheLogbook() {
        // Expansion state outlives the Logbook, so an expanded id staged here
        // would surface on a note the moment it's put back.
        store.add(text: "a", sourceApp: nil)
        let id = archiveSingleNoteAndShowLogbook()

        actions.toggleExpanded()

        XCTAssertTrue(selection.expandedIDs.isEmpty)
        XCTAssertEqual(selection.selectedIDs, [id], "no-op: the selection itself is untouched")
    }

    func testRestorePutsTheNoteBackInTheList() {
        store.add(text: "a", sourceApp: nil)
        let id = archiveSingleNoteAndShowLogbook()

        actions.restore(ids: [id])

        XCTAssertEqual(store.activeNotes.map(\.id), [id])
        XCTAssertTrue(store.archivedNotes.isEmpty)
    }

    // MARK: - move to list

    func testMoveToSectionMovesNotesAndClearsSelection() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        selection.selectAllNotes()

        actions.move(toSection: "Work")

        XCTAssertTrue(store.notes.allSatisfy { $0.listName == "Work" })
        XCTAssertTrue(selection.selectedIDs.isEmpty, "the moved-into-view/out-of-view selection shouldn't linger and risk a second accidental move")
    }

    func testMoveToSectionWithEmptySelectionIsNoOp() {
        store.add(text: "a", sourceApp: nil)

        actions.move(toSection: "Work")

        XCTAssertNil(store.notes[0].listName)
        XCTAssertTrue(store.sections.isEmpty)
    }

    // MARK: - Section commands

    func testRequestDeleteSectionDeletesAnEmptySectionWithoutAsking() {
        store.createSection(named: "Work")

        actions.requestDeleteSection("Work")

        XCTAssertNil(selection.sectionDeleteConfirmation)
        XCTAssertTrue(store.sections.isEmpty)
    }

    func testRequestDeleteSectionStagesTheConfirmationWhenItHasNotes() {
        store.createSection(named: "Work")
        store.add(text: "a", sourceApp: nil)

        actions.requestDeleteSection("Work")

        XCTAssertEqual(selection.sectionDeleteConfirmation?.name, "Work")
        XCTAssertEqual(selection.sectionDeleteConfirmation?.noteCount, 1)
        XCTAssertEqual(store.sections, ["Work"], "nothing is deleted until the dialog is answered")
    }

    func testSectionScopedCommandsDoNothingWithoutAnActiveSection() {
        store.createSection(named: "Work")
        store.add(text: "a", sourceApp: nil)
        store.toggleDone(ids: [store.notes[0].id])
        store.setActiveSection(nil)

        actions.renameActiveSection()
        actions.dissolveActiveSection()
        actions.requestDeleteActiveSection()
        actions.clearDoneInActiveSection()

        XCTAssertNil(selection.renamingSectionName)
        XCTAssertNil(selection.sectionDeleteConfirmation)
        XCTAssertEqual(store.sections, ["Work"])
        XCTAssertEqual(store.activeNotes.count, 1)
    }

    func testCreateAndRenameNewSectionSwitchesToItAndStartsTheRename() {
        actions.createAndRenameNewSection()

        XCTAssertEqual(store.sections.count, 1)
        XCTAssertEqual(store.activeSection, store.sections.first)
        XCTAssertEqual(selection.renamingSectionName, store.sections.first)
    }

    // MARK: - Duplicate note ids (corrupt store) regression

    /// Guards against `notes(for:)`/`allSelectedAreDone` trapping when
    /// `notes.json` was hand-edited to contain two notes sharing the same
    /// `id` (the file is user-facing via "Reveal Notes in Finder"). Before
    /// the duplicate-tolerant dictionary fix, `Dictionary(uniqueKeysWithValues:)`
    /// would crash the process on this input.
    func testActionsSurviveDuplicateNoteIDsInStore() {
        let duplicateID = UUID().uuidString
        let json = """
        {
          "version": 2,
          "sections": [],
          "activeSection": null,
          "notes": [
            {
              "id": "\(duplicateID)",
              "text": "first",
              "listName": null,
              "isDone": false,
              "createdAt": "2024-01-01T00:00:00Z",
              "sourceApp": null
            },
            {
              "id": "\(duplicateID)",
              "text": "second",
              "listName": null,
              "isDone": true,
              "createdAt": "2024-01-02T00:00:00Z",
              "sourceApp": null
            }
          ]
        }
        """
        try! json.data(using: .utf8)!.write(to: fileURL)

        let duplicateStore = NoteStore(fileURL: fileURL)
        let duplicateSelection = SelectionModel(store: duplicateStore)
        let duplicateActions = PanelActions(store: duplicateStore, selection: duplicateSelection)

        duplicateSelection.selectedIDs = Set(duplicateStore.notes.map(\.id))

        // Must not trap.
        _ = duplicateActions.allSelectedAreDone
        duplicateActions.toggleDone()
    }

    // MARK: - Mark done on copy

    func testCopyWithSettingOffLeavesDoneStateUnchanged() {
        PanelSettings.markDoneOnCopy = false
        store.add(text: "a", sourceApp: nil)
        let id = store.notes[0].id
        selection.selectSingle(id)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        actions.copy(pasteboard: pasteboard)

        XCTAssertFalse(store.notes[0].isDone)
    }

    func testCopyWithSettingOnMarksTheCopiedSelectionDone() {
        PanelSettings.markDoneOnCopy = true
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        let ids = store.notes.map(\.id)
        selection.selectSingle(ids[0])

        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        actions.copy(pasteboard: pasteboard)

        XCTAssertTrue(store.notes.first { $0.id == ids[0] }!.isDone)
        XCTAssertFalse(store.notes.first { $0.id == ids[1] }!.isDone, "only the copied note is marked")
    }

    func testCopyAsListWithSettingOnMarksAlreadyDoneNotesStayDoneWithoutToggling() {
        PanelSettings.markDoneOnCopy = true
        store.add(text: "a", sourceApp: nil)
        let id = store.notes[0].id
        store.toggleDone(ids: [id])
        selection.selectSingle(id)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        actions.copyAsList(pasteboard: pasteboard)

        XCTAssertTrue(store.notes[0].isDone, "an already-done note must stay done, not toggle back off")
    }

    func testCopyInTheLogbookWithSettingOnNeverMarksArchivedNotesDone() {
        PanelSettings.markDoneOnCopy = true
        store.add(text: "archived note", sourceApp: nil)
        let id = archiveSingleNoteAndShowLogbook()

        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        actions.copy(pasteboard: pasteboard)

        // The note was already marked done (and cleared) to get into the
        // Logbook; the point of this test is that copying there doesn't
        // stamp a fresh `completedAt` or otherwise re-touch it.
        let completedAt = store.notes.first { $0.id == id }?.completedAt
        actions.copy(pasteboard: pasteboard)
        XCTAssertEqual(store.notes.first { $0.id == id }?.completedAt, completedAt, "copying in the Logbook must never re-mark an archived note")
    }

    func testCopyAllAsListWithSettingOnMarksEveryVisibleLiveNoteDone() {
        PanelSettings.markDoneOnCopy = true
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        store.add(text: "c", sourceApp: nil)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        actions.copyAllAsList(pasteboard: pasteboard)

        XCTAssertTrue(store.notes.allSatisfy(\.isDone))
    }
}

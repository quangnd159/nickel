import XCTest
@testable import Nickel

final class PanelActionsTests: XCTestCase {
    private var tempDirectory: URL!
    private var fileURL: URL!
    private var store: NoteStore!
    private var selection: SelectionModel!
    private var actions: PanelActions!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        fileURL = tempDirectory.appendingPathComponent("notes.json")
        store = NoteStore(fileURL: fileURL)
        selection = SelectionModel(store: store)
        actions = PanelActions(store: store, selection: selection)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
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
}

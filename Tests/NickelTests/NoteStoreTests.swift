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

        XCTAssertEqual(store.notes.map(\.id), [idB])
    }

    func testClearDoneGlobalWhenNoActiveSection() {
        store.createSection(named: "Work")
        store.add(text: "a", sourceApp: nil)
        store.setActiveSection(nil)
        store.add(text: "b", sourceApp: nil)
        store.toggleDone(ids: Set(store.notes.map(\.id)))

        store.clearDone()

        XCTAssertTrue(store.notes.isEmpty)
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

        XCTAssertEqual(store.notes.map(\.id), [idB])
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
    }

    // MARK: - Corruption recovery

    func testCorruptFileIsMovedAsideAndStoreStartsEmpty() {
        let backupURL = tempDirectory.appendingPathComponent("notes.json.bak")
        try! Data([0xFF, 0x00, 0x12]).write(to: fileURL)

        let reloaded = NoteStore(fileURL: fileURL)

        XCTAssertTrue(reloaded.notes.isEmpty)
        XCTAssertTrue(reloaded.sections.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testCorruptFileOverwritesExistingBackup() {
        let backupURL = tempDirectory.appendingPathComponent("notes.json.bak")
        let oldBackupContent = "old backup".data(using: .utf8)!
        try! oldBackupContent.write(to: backupURL)
        let invalidJSON = "{not json".data(using: .utf8)!
        try! invalidJSON.write(to: fileURL)

        _ = NoteStore(fileURL: fileURL)

        let backupContent = try! Data(contentsOf: backupURL)
        XCTAssertEqual(backupContent, invalidJSON)
        XCTAssertNotEqual(backupContent, oldBackupContent)
    }

    func testUnparseableJSONObjectIsTreatedAsCorrupt() {
        let backupURL = tempDirectory.appendingPathComponent("notes.json.bak")
        try! "[1, 2, 3]".data(using: .utf8)!.write(to: fileURL)

        let reloaded = NoteStore(fileURL: fileURL)

        XCTAssertTrue(reloaded.notes.isEmpty)
        XCTAssertTrue(reloaded.sections.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
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
}

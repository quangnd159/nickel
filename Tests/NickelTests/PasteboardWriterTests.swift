import AppKit
import XCTest
@testable import Nickel

final class PasteboardWriterTests: XCTestCase {
    private var tempDirectory: URL!
    private var fileURL: URL!
    private var store: NoteStore!
    private var pasteboard: NSPasteboard!

    /// A minimal valid 1x1 PNG, so image-type detection has real bytes to
    /// read rather than a placeholder that would fail decoding anyway (this
    /// path only cares about UTI + raw data, not decodability).
    private static let onePixelPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        fileURL = tempDirectory.appendingPathComponent("notes.json")
        store = NoteStore(fileURL: fileURL)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("test-\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.clearContents()
        pasteboard = nil
        try? FileManager.default.removeItem(at: tempDirectory)
        store = nil
        tempDirectory = nil
        fileURL = nil
        super.tearDown()
    }

    private func pngData() -> Data {
        Data(base64Encoded: Self.onePixelPNGBase64)!
    }

    // MARK: - text-only

    func testTextOnlyNoteProducesSingleStringItem() {
        store.add(text: "hello world", sourceApp: nil)

        PasteboardWriter.copy(notes: store.notes, store: store, pasteboard: pasteboard)

        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        let item = pasteboard.pasteboardItems![0]
        XCTAssertEqual(item.string(forType: .string), "hello world")
        XCTAssertNil(item.string(forType: .fileURL))
    }

    // MARK: - image attachment

    func testImageAttachmentProducesFileURLAndImageDataItemPlusTrailingString() throws {
        let source = tempDirectory.appendingPathComponent("shot.png")
        try pngData().write(to: source)

        _ = store.add(
            text: "a screenshot",
            attachments: [(sourceURL: source, filename: "shot.png", contentType: "public.png")],
            sourceApp: nil
        )

        PasteboardWriter.copy(notes: store.notes, store: store, pasteboard: pasteboard)

        let items = pasteboard.pasteboardItems!
        XCTAssertEqual(items.count, 2)

        let attachmentItem = items[0]
        XCTAssertTrue(attachmentItem.types.contains(.fileURL))
        XCTAssertTrue(attachmentItem.types.contains(NSPasteboard.PasteboardType("public.png")))
        XCTAssertEqual(attachmentItem.data(forType: NSPasteboard.PasteboardType("public.png")), pngData())

        let note = store.notes[0]
        let expectedURL = store.url(for: note.attachments[0], in: note)
        XCTAssertEqual(attachmentItem.string(forType: .fileURL), expectedURL.absoluteString)

        let textItem = items[1]
        XCTAssertEqual(textItem.string(forType: .string), "a screenshot\nshot.png")
    }

    // MARK: - non-image attachment

    func testNonImageAttachmentProducesFileURLOnlyItem() throws {
        let source = tempDirectory.appendingPathComponent("notes.txt")
        try "hello".write(to: source, atomically: true, encoding: .utf8)

        _ = store.add(
            text: "",
            attachments: [(sourceURL: source, filename: "notes.txt", contentType: "public.text")],
            sourceApp: nil
        )

        PasteboardWriter.copy(notes: store.notes, store: store, pasteboard: pasteboard)

        let items = pasteboard.pasteboardItems!
        XCTAssertEqual(items.count, 2)

        let attachmentItem = items[0]
        XCTAssertEqual(attachmentItem.types, [.fileURL])
    }

    // MARK: - missing file

    func testMissingAttachmentFileStillYieldsFileURLItemWithoutCrashing() {
        // Build a note with an attachment record whose backing file was
        // never written (simulates a file removed out from under us).
        let noteID = UUID()
        let attachment = Attachment(id: UUID(), filename: "ghost.png", contentType: "public.png")
        let note = Note(
            id: noteID,
            text: "gone",
            listName: nil,
            isDone: false,
            createdAt: Date(),
            sourceApp: nil,
            attachments: [attachment]
        )

        PasteboardWriter.copy(notes: [note], store: store, pasteboard: pasteboard)

        let items = pasteboard.pasteboardItems!
        XCTAssertEqual(items.count, 2)
        let attachmentItem = items[0]
        XCTAssertEqual(attachmentItem.types, [.fileURL])
        XCTAssertEqual(attachmentItem.string(forType: .fileURL), store.url(for: attachment, in: note).absoluteString)
    }

    // MARK: - combined text unchanged

    func testCombinedTextContentUnchangedFromPriorBehavior() {
        store.add(text: "first", sourceApp: nil)
        store.add(text: "second", sourceApp: nil)

        PasteboardWriter.copy(notes: store.notes, store: store, pasteboard: pasteboard)

        let items = pasteboard.pasteboardItems!
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].string(forType: .string), "first\n\nsecond")
    }

    func testCopyAsListCombinedTextUnchanged() {
        store.add(text: "first", sourceApp: nil)
        store.add(text: "second", sourceApp: nil)

        PasteboardWriter.copyAsList(notes: store.notes, store: store, pasteboard: pasteboard)

        let items = pasteboard.pasteboardItems!
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].string(forType: .string), "- first\n- second")
    }
}

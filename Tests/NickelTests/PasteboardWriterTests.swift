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
        XCTAssertEqual(item.types, [.string])
        XCTAssertEqual(item.string(forType: .string), "hello world")
        XCTAssertNil(item.string(forType: .fileURL))
    }

    // MARK: - image attachment: rich item first, then unchanged attachment item

    func testImageAttachmentProducesRichItemThenFileURLAndImageDataItem() throws {
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

        // First item: the rich representation, carrying rtfd + rtf + string.
        let richItem = items[0]
        XCTAssertTrue(richItem.types.contains(.rtfd))
        XCTAssertTrue(richItem.types.contains(.rtf))
        XCTAssertTrue(richItem.types.contains(.string))
        XCTAssertEqual(richItem.string(forType: .string), "a screenshot\nshot.png")

        // Second item: the unchanged per-attachment item.
        let attachmentItem = items[1]
        XCTAssertTrue(attachmentItem.types.contains(.fileURL))
        XCTAssertTrue(attachmentItem.types.contains(NSPasteboard.PasteboardType("public.png")))
        XCTAssertEqual(attachmentItem.data(forType: NSPasteboard.PasteboardType("public.png")), pngData())

        let note = store.notes[0]
        let expectedURL = store.url(for: note.attachments[0], in: note)
        XCTAssertEqual(attachmentItem.string(forType: .fileURL), expectedURL.absoluteString)
    }

    func testImageAttachmentRTFDRoundTripsTextAndImageBytes() throws {
        let source = tempDirectory.appendingPathComponent("shot.png")
        try pngData().write(to: source)

        _ = store.add(
            text: "a screenshot",
            attachments: [(sourceURL: source, filename: "shot.png", contentType: "public.png")],
            sourceApp: nil
        )

        PasteboardWriter.copy(notes: store.notes, store: store, pasteboard: pasteboard)

        let richItem = pasteboard.pasteboardItems![0]
        let rtfdData = try XCTUnwrap(richItem.data(forType: .rtfd))
        let decoded = try XCTUnwrap(NSAttributedString(rtfd: rtfdData, documentAttributes: nil))

        XCTAssertTrue(decoded.string.hasPrefix("a screenshot"))

        var foundAttachment: NSTextAttachment?
        decoded.enumerateAttribute(.attachment, in: NSRange(location: 0, length: decoded.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment {
                foundAttachment = attachment
            }
        }
        let attachment = try XCTUnwrap(foundAttachment)
        let wrapper = try XCTUnwrap(attachment.fileWrapper)
        XCTAssertEqual(wrapper.preferredFilename, "shot.png")
        XCTAssertEqual(wrapper.regularFileContents, pngData())
    }

    // MARK: - non-image attachment

    func testNonImageAttachmentProducesStringOnlyRichItemThenFileURLOnlyItem() throws {
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

        // No image anywhere in the batch, so the rich item degrades to a
        // plain string, matching pre-RTFD behavior.
        let richItem = items[0]
        XCTAssertEqual(richItem.types, [.string])
        XCTAssertEqual(richItem.string(forType: .string), "notes.txt")

        let attachmentItem = items[1]
        XCTAssertEqual(attachmentItem.types, [.fileURL])
    }

    // MARK: - mixed image + non-image attachments in one batch

    func testMixedImageAndNonImageAttachmentsInBatchProducesRichItemAndUnchangedAttachmentItems() throws {
        let imageSource = tempDirectory.appendingPathComponent("shot.png")
        try pngData().write(to: imageSource)
        let docSource = tempDirectory.appendingPathComponent("notes.txt")
        try "hello".write(to: docSource, atomically: true, encoding: .utf8)

        _ = store.add(
            text: "a screenshot",
            attachments: [(sourceURL: imageSource, filename: "shot.png", contentType: "public.png")],
            sourceApp: nil
        )
        _ = store.add(
            text: "",
            attachments: [(sourceURL: docSource, filename: "notes.txt", contentType: "public.text")],
            sourceApp: nil
        )

        PasteboardWriter.copy(notes: store.notes, store: store, pasteboard: pasteboard)

        let items = pasteboard.pasteboardItems!
        // rich item + 2 attachment items
        XCTAssertEqual(items.count, 3)

        let richItem = items[0]
        XCTAssertTrue(richItem.types.contains(.rtfd))
        XCTAssertEqual(richItem.string(forType: .string), "a screenshot\nshot.png\n\nnotes.txt")

        let rtfdData = try XCTUnwrap(richItem.data(forType: .rtfd))
        let decoded = try XCTUnwrap(NSAttributedString(rtfd: rtfdData, documentAttributes: nil))

        var attachmentCount = 0
        decoded.enumerateAttribute(.attachment, in: NSRange(location: 0, length: decoded.length)) { value, _, _ in
            if value != nil { attachmentCount += 1 }
        }
        // Exactly one embedded NSTextAttachment (the image); the non-image
        // attachment contributes plain filename text instead.
        XCTAssertEqual(attachmentCount, 1)
        XCTAssertTrue(decoded.string.contains("notes.txt"))

        // Per-attachment items are unchanged: image gets fileURL + image
        // data, non-image gets fileURL only.
        let imageAttachmentItem = items[1]
        XCTAssertTrue(imageAttachmentItem.types.contains(.fileURL))
        XCTAssertTrue(imageAttachmentItem.types.contains(NSPasteboard.PasteboardType("public.png")))

        let docAttachmentItem = items[2]
        XCTAssertEqual(docAttachmentItem.types, [.fileURL])
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

        // Unreadable file means no NSTextAttachment gets embedded, so the
        // rich item degrades to plain string, same as the no-image path.
        let richItem = items[0]
        XCTAssertEqual(richItem.types, [.string])

        let attachmentItem = items[1]
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

    // MARK: - repeated writes of one layout

    /// Regression test: an `NSPasteboardItem` can be attached to a pasteboard
    /// only once, and the sequential-paste flow writes one layout repeatedly
    /// (full on copy, attachments-only on arm and every re-stage). Caching
    /// built items in `Layout` left the pasteboard empty on the second write.
    func testLayoutSurvivesRepeatedWrites() throws {
        let source = tempDirectory.appendingPathComponent("shot.png")
        try pngData().write(to: source)
        _ = store.add(
            text: "a screenshot",
            attachments: [(sourceURL: source, filename: "shot.png", contentType: "public.png")],
            sourceApp: nil
        )

        let layout = try XCTUnwrap(PasteboardWriter.copy(notes: store.notes, store: store, pasteboard: pasteboard))

        PasteboardWriter.writeAttachmentsOnly(layout, pasteboard: pasteboard)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        XCTAssertNotNil(pasteboard.pasteboardItems?.first?.string(forType: .fileURL))

        PasteboardWriter.writeTextOnly(layout, pasteboard: pasteboard)
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.string(forType: .string), "a screenshot\nshot.png")

        PasteboardWriter.writeAttachmentsOnly(layout, pasteboard: pasteboard)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        XCTAssertNotNil(pasteboard.pasteboardItems?.first?.string(forType: .fileURL))

        PasteboardWriter.write(layout, pasteboard: pasteboard)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 2)
        XCTAssertNotNil(pasteboard.pasteboardItems?.first?.data(forType: .rtfd))
    }
}

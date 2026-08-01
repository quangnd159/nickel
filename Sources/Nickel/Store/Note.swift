import Foundation

struct Note: Identifiable, Codable, Equatable {
    var id: UUID
    var text: String
    var listName: String?   // nil = ungrouped (shown at top)
    var isDone: Bool
    var createdAt: Date
    var sourceApp: String?
    /// Files/images attached to this note (Copper-style). A note with
    /// attachments and empty text is valid (an attachment-only note).
    var attachments: [Attachment]

    init(
        id: UUID,
        text: String,
        listName: String?,
        isDone: Bool,
        createdAt: Date,
        sourceApp: String?,
        attachments: [Attachment] = []
    ) {
        self.id = id
        self.text = text
        self.listName = listName
        self.isDone = isDone
        self.createdAt = createdAt
        self.sourceApp = sourceApp
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, listName, isDone, createdAt, sourceApp, attachments
    }

    /// Custom decoding (rather than the synthesized initializer) so files
    /// written before attachments existed keep loading: `attachments` is
    /// `decodeIfPresent`, defaulting to `[]` when the key is missing. The
    /// store format stays version 2 — this is purely additive.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        listName = try container.decodeIfPresent(String.self, forKey: .listName)
        isDone = try container.decode(Bool.self, forKey: .isDone)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
        attachments = try container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
    }
}

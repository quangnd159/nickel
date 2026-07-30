import Foundation

struct Note: Identifiable, Codable, Equatable {
    var id: UUID
    var text: String
    var listName: String?   // nil = ungrouped (shown at top)
    var isDone: Bool
    var createdAt: Date
    var sourceApp: String?
}

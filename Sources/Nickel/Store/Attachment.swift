import Foundation

/// A file or image attached to a note (Copper-style). Only display metadata
/// lives here; the actual file sits on disk under `NoteStore`'s attachments
/// directory, keyed by the owning note's id and this attachment's id (see
/// `NoteStore.url(for:in:)`).
struct Attachment: Identifiable, Codable, Equatable {
    var id: UUID
    /// Original/display filename (e.g. "Screenshot.png"), shown in the UI and
    /// used as the visible name when the file is opened or copied elsewhere.
    var filename: String
    /// The UTType identifier of the file's content (e.g. "public.png"),
    /// stored as a plain string since `UTType` itself isn't `Codable`.
    var contentType: String
}

import Foundation

/// The composer's staged destination-section chip: at most one at a time.
/// Kept as a plain value type (rather than logic inlined into `PanelView`'s
/// `@State`) so staging, replacing, and removing it are unit-testable
/// without SwiftUI. `PanelView` holds one in `@State` and renders `name` as
/// the chip; `stageSection(named:)`/`removeStagedSection()` on `PanelView`
/// forward to `stage(named:)`/`remove()` here, which is what the
/// "#"-triggered suggestion popup calls when a row is accepted (see
/// `ComposerSectionSuggestions`).
struct ComposerSectionChip: Equatable {
    private(set) var name: String?

    /// Stages `name`, replacing any previously staged chip. Trims
    /// whitespace; a blank name is a no-op (nothing to stage).
    mutating func stage(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.name = trimmed
    }

    mutating func remove() {
        name = nil
    }
}

/// What committing the composer should do, given its current text, whether
/// any attachments are staged, and the staged section chip (if any). Pure
/// decision logic factored out of `PanelView.commitComposer` so it's
/// unit-testable; `PanelView` is the one place that actually calls
/// `NoteStore` based on the result.
enum ComposerCommitPlan: Equatable {
    /// Nothing to do: no text, no attachments, no staged chip.
    case noop
    /// A chip is staged but there's no text and no attachments: create (or
    /// switch to) `section` only — no note is added. Return on an empty
    /// field right after staging a chip is "take me to that section".
    case sectionOnly(section: String)
    /// Add a note. `section` is the chip's staged destination (create/switch
    /// to it first) when one was staged, otherwise `nil` (lands in whatever
    /// section is already active, unchanged).
    case addNote(section: String?)
}

enum ComposerCommit {
    /// - Parameters:
    ///   - text: the composer's current text (not yet trimmed).
    ///   - hasAttachments: whether any attachments are staged.
    ///   - pendingSection: the staged section chip's name, if any.
    static func plan(text: String, hasAttachments: Bool, pendingSection: String?) -> ComposerCommitPlan {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let pendingSection {
            if trimmedText.isEmpty && !hasAttachments {
                return .sectionOnly(section: pendingSection)
            }
            return .addNote(section: pendingSection)
        }

        guard !trimmedText.isEmpty || hasAttachments else { return .noop }
        return .addNote(section: nil)
    }
}

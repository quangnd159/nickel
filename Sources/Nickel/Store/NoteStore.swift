import Foundation

/// Persistent store of notes, backed by a JSON file in Application Support.
/// Mutations are applied synchronously in memory and saved to disk on a short
/// debounce so rapid edits don't thrash the filesystem.
final class NoteStore: ObservableObject {
    @Published private(set) var notes: [Note] {
        didSet { rebuildNotesByID() }
    }

    /// O(1) row lookup; rebuilt wherever `notes` is assigned/mutated. The
    /// by-id read contract (see CLAUDE.md) is unchanged — only its cost.
    private(set) var notesByID: [UUID: Note] = [:]

    /// Bumped every time `notes` is assigned/mutated, alongside `notesByID`.
    /// Lets callers (the list table's update short-circuit) tell "notes
    /// changed at all" apart from "notes changed in a way that affects rows
    /// or heights" without diffing the array themselves.
    private(set) var notesRevision: Int = 0

    /// Explicit sections (Copper-style groups), in display order. This is now
    /// the source of truth for a section's existence and ordering — it can
    /// contain sections with no notes in them yet, unlike the old
    /// notes-derived `listNames`.
    @Published private(set) var sections: [String]

    /// The section notes are currently captured into, and the panel's
    /// focused view when non-nil. `nil` means "Show All".
    @Published private(set) var activeSection: String?

    /// Non-nil while the most recent notes.json write failed; cleared by the
    /// next successful write. Set on the main thread (write runs on saveQueue).
    @Published private(set) var saveError: String?

    let fileURL: URL
    private var saveWorkItem: DispatchWorkItem?
    private let saveDebounceInterval: TimeInterval = 0.5
    private let maxSaveDeferral: TimeInterval = 3.0
    /// When the first not-yet-written mutation of the current coalescing burst
    /// happened; nil when no save is pending.
    private var firstPendingSaveAt: Date?
    /// Serial queue that performs the actual disk write. Snapshots are taken
    /// on the main thread in mutation order and enqueued here in that same
    /// order, so writes can never reorder relative to each other.
    private let saveQueue = DispatchQueue(label: "com.nickel.notestore.save", qos: .utility)

    /// Hard cap on a single note's length. Guards against runaway captures
    /// (e.g. selecting an entire huge document) bloating the notes file and
    /// the UI; text past this length is truncated with a trailing ellipsis.
    private static let maxNoteLength = 20_000

    /// Consecutive captures of the *same* text within this window are
    /// treated as accidental duplicates (e.g. a double-shift firing twice on
    /// the same selection) and are not added again.
    private static let duplicateCaptureWindow: TimeInterval = 2.0

    private var lastCapturedText: String?
    private var lastCapturedAt: Date?

    init(fileURL: URL? = nil) {
        // Dev/test override: NICKEL_STORE_PATH points the store at an
        // alternate JSON file instead of the real Application Support one.
        let envOverride = ProcessInfo.processInfo.environment["NICKEL_STORE_PATH"].map { URL(fileURLWithPath: $0) }
        self.fileURL = fileURL ?? envOverride ?? Self.defaultFileURL()

        let loaded = Self.load(from: self.fileURL)
        self.notes = loaded.notes
        self.sections = loaded.sections
        self.activeSection = loaded.activeSection
        // `didSet` doesn't fire for the initial assignment above (still
        // inside `init`), so the index needs its own first build.
        rebuildNotesByID()

        // A failed/corrupt load leaves `notes` empty without those notes
        // actually being gone (see `load`'s failure paths), so sweeping now
        // would delete every attachment directory as "orphaned." Only sweep
        // when the load genuinely reflects what's on disk.
        if loaded.loadedCleanly {
            sweepOrphanedAttachmentDirectories()
        }
    }

    private func rebuildNotesByID() {
        notesByID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        notesRevision += 1
    }

    // MARK: - Derived views of `notes`

    /// Every note that hasn't been cleared into the Logbook — what the panel
    /// shows, searches, counts, and acts on. Archived notes stay in `notes`
    /// (nothing is deleted by clearing, and the launch-time attachment sweep
    /// derives its known ids from `notes`), so every consumer outside the
    /// Logbook reads through here instead.
    var activeNotes: [Note] {
        notes.filter { $0.archivedAt == nil }
    }

    /// The Logbook's contents: cleared notes, most recently cleared first.
    ///
    /// A batch clear stamps every note in it with one shared `archivedAt`, so
    /// the tie is broken by `createdAt` (newest first, matching the primary
    /// order) rather than left to `sorted`, whose stability is unspecified.
    var archivedNotes: [Note] {
        notes
            .filter { $0.archivedAt != nil }
            .sorted { lhs, rhs in
                let lhsArchived = lhs.archivedAt ?? .distantPast
                let rhsArchived = rhs.archivedAt ?? .distantPast
                if lhsArchived != rhsArchived { return lhsArchived > rhsArchived }
                return lhs.createdAt > rhs.createdAt
            }
    }

    // MARK: - Mutations

    /// Adds a note. `isCapture` marks this as coming from the double-shift
    /// capture flow (as opposed to the composer), which enables the
    /// duplicate-capture debounce below; composer submissions always add.
    /// New notes are captured into the active section, if any.
    func add(text: String, sourceApp: String?, isCapture: Bool = false) {
        let trimmedText = Self.capped(text)

        if isCapture {
            let now = Date()
            if let lastCapturedText, let lastCapturedAt,
               lastCapturedText == trimmedText,
               now.timeIntervalSince(lastCapturedAt) <= Self.duplicateCaptureWindow {
                return
            }
            lastCapturedText = trimmedText
            lastCapturedAt = now
        }

        let note = Note(
            id: UUID(),
            text: trimmedText,
            listName: activeSection,
            isDone: false,
            createdAt: Date(),
            sourceApp: sourceApp
        )
        notes.append(note)
        scheduleSave()
    }

    private static func capped(_ text: String) -> String {
        guard text.count > maxNoteLength else { return text }
        let truncated = text.prefix(maxNoteLength)
        return truncated + "…"
    }

    /// Adds a note carrying file/image attachments (Copper-style intake: the
    /// composer's paperclip picker, drag & drop, or paste). Each attachment's
    /// source file is copied into the new note's attachments directory; a
    /// failed copy just skips that attachment (logged) rather than losing the
    /// whole note. `text` may be empty — attachment-only notes are valid.
    /// Always lands in the active section, like `add(text:sourceApp:)`.
    ///
    /// Returns the indices (into `attachments`) of inputs that failed to
    /// copy, so the caller can keep those staged rather than discarding
    /// their only copy (e.g. a pasted screenshot that lives only in a temp
    /// staging directory).
    @discardableResult
    func add(text: String, attachments: [(sourceURL: URL, filename: String, contentType: String)], sourceApp: String?) -> [Int] {
        let noteID = UUID()
        let (savedAttachments, failedIndices) = copyAttachments(attachments, intoNoteDirectoryFor: noteID)

        let note = Note(
            id: noteID,
            text: Self.capped(text),
            listName: activeSection,
            isDone: false,
            createdAt: Date(),
            sourceApp: sourceApp,
            attachments: savedAttachments
        )
        notes.append(note)
        scheduleSave()
        return failedIndices
    }

    /// Copies each `(sourceURL, filename, contentType)` input into
    /// `noteID`'s attachments directory (creating it on demand), returning
    /// the `Attachment`s that copied successfully alongside the indices
    /// (into `inputs`) of the ones that didn't.
    private func copyAttachments(
        _ inputs: [(sourceURL: URL, filename: String, contentType: String)],
        intoNoteDirectoryFor noteID: UUID
    ) -> (saved: [Attachment], failedIndices: [Int]) {
        guard !inputs.isEmpty else { return ([], []) }

        let destinationDirectory = attachmentsDirectory.appendingPathComponent(noteID.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        } catch {
            NSLog("NoteStore: failed to create attachments directory: \(error)")
            return ([], Array(inputs.indices))
        }

        var saved: [Attachment] = []
        var failedIndices: [Int] = []
        for (index, input) in inputs.enumerated() {
            let attachment = Attachment(id: UUID(), filename: input.filename, contentType: input.contentType)
            let destination = destinationDirectory.appendingPathComponent(attachmentFilename(attachment))
            do {
                try FileManager.default.copyItem(at: input.sourceURL, to: destination)
                saved.append(attachment)
            } catch {
                NSLog("NoteStore: failed to copy attachment \"\(input.filename)\": \(error)")
                failedIndices.append(index)
            }
        }
        return (saved, failedIndices)
    }

    func update(id: UUID, text: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].text = text
        scheduleSave()
    }

    func toggleDone(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let now = Date()
        for index in notes.indices where ids.contains(notes[index].id) {
            notes[index].isDone.toggle()
            // The completion stamp follows the done state, so the Logbook
            // can say when a note was finished even if it's cleared later.
            notes[index].completedAt = notes[index].isDone ? now : nil
        }
        scheduleSave()
    }

    /// Marks the given notes done, leaving already-done notes untouched
    /// (unlike `toggleDone`, which would flip them back to not-done). Used
    /// by "mark as done when copied", where re-copying an already-done note
    /// must never undo it.
    func markDone(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let now = Date()
        var didChange = false
        for index in notes.indices where ids.contains(notes[index].id) && !notes[index].isDone {
            notes[index].isDone = true
            notes[index].completedAt = now
            didChange = true
        }
        guard didChange else { return }
        scheduleSave()
    }

    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let deletedNoteIDs = notes.filter { ids.contains($0.id) }.map(\.id)
        notes.removeAll { ids.contains($0.id) }
        for noteID in deletedNoteIDs {
            removeAttachmentsDirectory(forNoteID: noteID)
        }
        scheduleSave()
    }

    /// Moves notes to `sectionName` (`nil` = ungrouped). Defensive: if
    /// `sectionName` isn't a known section, it's appended to `sections` —
    /// this shouldn't happen in practice since the "Move to" submenu only
    /// lists existing sections, but guards against the section list and note
    /// data ever drifting apart.
    func move(ids: Set<UUID>, toSection sectionName: String?) {
        guard !ids.isEmpty else { return }
        ensureSectionExists(sectionName)
        for index in notes.indices where ids.contains(notes[index].id) {
            notes[index].listName = sectionName
        }
        scheduleSave()
    }

    /// The drag-and-drop move: puts `ids` into `sectionName` *and* at a
    /// position, landing them immediately before `beforeID` — or at the end of
    /// that section's notes when `beforeID` is `nil`.
    ///
    /// `ids` is ordered (the dragged rows in the order they appear on screen)
    /// and that relative order is preserved at the destination, which is why
    /// this takes an array where `move(ids:toSection:)` takes a set: that one
    /// only ever changes which section notes belong to, never where they sit.
    ///
    /// Display order is `notes` order — `activeNotes` is a filter and the
    /// sections are derived by `listName` — so repositioning here is what the
    /// list shows. Archived notes share the array but are ordered by
    /// `archivedAt` when the Logbook reads them, so moving live notes past
    /// them can't disturb the Logbook.
    func move(ids: [UUID], toSection sectionName: String?, before beforeID: UUID?) {
        guard !ids.isEmpty else { return }
        ensureSectionExists(sectionName)

        let moving = Set(ids)
        let lifted: [Note] = ids.compactMap { id in
            guard var note = notes.first(where: { $0.id == id }) else { return nil }
            note.listName = sectionName
            return note
        }
        guard !lifted.isEmpty else { return }

        // Resolved against the array as it stands, *then* corrected for the
        // notes about to be lifted out ahead of it. Resolving after the lift
        // instead would turn a drop onto the dragged notes themselves — whose
        // `beforeID` is one of them, and so no longer findable — into a move to
        // the end of the section, when it should do nothing at all.
        let target: Int
        if let beforeID, let index = notes.firstIndex(where: { $0.id == beforeID }) {
            target = index
        } else if let last = notes.lastIndex(where: { $0.archivedAt == nil && $0.listName == sectionName }) {
            target = last + 1
        } else {
            target = notes.endIndex
        }
        let liftedBeforeTarget = notes[..<target].reduce(into: 0) { count, note in
            if moving.contains(note.id) { count += 1 }
        }

        var reordered = notes.filter { !moving.contains($0.id) }
        reordered.insert(contentsOf: lifted, at: target - liftedBeforeTarget)
        notes = reordered
        scheduleSave()
    }

    /// Defensive: a section that isn't known yet is appended. This shouldn't
    /// happen in practice — every entry point picks from the existing list —
    /// but it guards against the section list and the note data drifting apart.
    private func ensureSectionExists(_ sectionName: String?) {
        guard let sectionName, !sections.contains(sectionName) else { return }
        sections.append(sectionName)
    }

    /// Renames every note in section `oldName` to `newName`, and updates the
    /// `sections` entry (and `activeSection`, if it pointed at `oldName`) to
    /// match. If `newName` (case-insensitively) matches an already-existing
    /// section, the two merge under that existing section's casing. Trims
    /// whitespace; a blank result after trimming is a no-op (Finder leaves
    /// the name unchanged rather than allowing an empty folder name).
    ///
    /// Archived notes are renamed too, deliberately — unlike `dissolveSection`
    /// and `deleteSection`, which leave the Logbook's record alone. The
    /// section still exists here, just under a new name, so a note put back
    /// from the Logbook has to land in it rather than come back ungrouped.
    func renameSection(from oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName else { return }

        // If an existing (different) section already has this name
        // case-insensitively, merge into it using its existing casing.
        // The section being renamed itself is excluded so case-only
        // renames (e.g. "work" -> "Work") fall through to the in-place
        // rename branch below instead of matching themselves.
        let canonicalName = sections.first { $0 != oldName && $0.caseInsensitiveCompare(trimmed) == .orderedSame } ?? trimmed

        for index in notes.indices where notes[index].listName == oldName {
            notes[index].listName = canonicalName
        }

        if canonicalName == trimmed {
            // No merge: just rename the section entry in place, preserving order.
            if let sectionIndex = sections.firstIndex(of: oldName) {
                sections[sectionIndex] = canonicalName
            }
        } else {
            // Merge: the destination section already exists, so drop the old one.
            sections.removeAll { $0 == oldName }
        }

        if activeSection == oldName {
            activeSection = canonicalName
        }

        scheduleSave()
    }

    /// A fresh, never-yet-used section name: "New Section", "New Section 2",
    /// "New Section 3", … (case-insensitive comparison against existing
    /// section names).
    func uniqueProvisionalSectionName() -> String {
        let existing = Set(sections.map { $0.lowercased() })
        guard existing.contains("new section") else { return "New Section" }

        var suffix = 2
        while existing.contains("new section \(suffix)") {
            suffix += 1
        }
        return "New Section \(suffix)"
    }

    /// Creates (or switches to) a section by name, then makes it active.
    /// Trims whitespace; a case-insensitive match against an existing section
    /// switches to it (adopting its existing casing) rather than creating a
    /// duplicate.
    func createSection(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let canonicalName = sections.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame } ?? trimmed
        if !sections.contains(canonicalName) {
            sections.append(canonicalName)
        }
        activeSection = canonicalName
        scheduleSave()
    }

    /// Switches the active section (`nil` = Show All). No-op if `name` isn't
    /// a known section.
    func setActiveSection(_ name: String?) {
        guard name == nil || sections.contains(name!) else { return }
        activeSection = name
        scheduleSave()
    }

    /// Steps the active section forward (`direction: 1`) or backward
    /// (`direction: -1`) through the cycle Show All → each section in
    /// `sections` order → wraps back to Show All. Shared by the panel's
    /// ⇧⌘]/⇧⌘[ handling and the View menu's Next/Previous Section items, so
    /// the cycle logic lives in one place.
    func cycleActiveSection(direction: Int) {
        guard !sections.isEmpty else { return }

        // The cycle is Show All (nil) followed by each section name; index 0
        // is Show All.
        let currentIndex = activeSection.flatMap { sections.firstIndex(of: $0).map { $0 + 1 } } ?? 0
        let count = sections.count + 1
        let nextIndex = ((currentIndex + direction) % count + count) % count
        setActiveSection(nextIndex == 0 ? nil : sections[nextIndex - 1])
    }

    /// Notes survive; the section grouping disappears (all matching notes'
    /// `listName` is cleared, the section is removed from `sections`, and if
    /// it was active, `activeSection` resets to Show All).
    ///
    /// Only live notes are touched: a note already in the Logbook keeps the
    /// section name it was cleared from as part of that record, and
    /// `restore(ids:)` ungroups it if the section is gone by then.
    func dissolveSection(_ name: String) {
        let ids = Set(activeNotes.filter { $0.listName == name }.map(\.id))
        for index in notes.indices where ids.contains(notes[index].id) {
            notes[index].listName = nil
        }
        sections.removeAll { $0 == name }
        if activeSection == name {
            activeSection = nil
        }
        scheduleSave()
    }

    /// Deletes `name` and every live note in it — the opposite of
    /// `dissolveSection`, which keeps the notes. Routed through
    /// `delete(ids:)` so attachment directories are cleaned up like any
    /// other note deletion. Notes already in the Logbook are left alone:
    /// deleting a section isn't a way to silently empty the record of
    /// what was cleared. No-op if `name` isn't a known section.
    func deleteSection(_ name: String) {
        guard sections.contains(name) else { return }
        let ids = Set(activeNotes.filter { $0.listName == name }.map(\.id))
        if !ids.isEmpty {
            delete(ids: ids)
        }
        sections.removeAll { $0 == name }
        if activeSection == name {
            activeSection = nil
        }
        scheduleSave()
    }

    /// Archives `name` and every live note in it into the Logbook — the
    /// recoverable counterpart to `deleteSection`. Stamps `archivedAt` on
    /// each live note (notes already in the Logbook are left untouched,
    /// same as `deleteSection`), then removes the section from `sections`.
    /// Since the section is gone, `restore(ids:)` will ungroup these notes
    /// when they're put back, the same as any other note whose section
    /// disappeared in the meantime. No-op if `name` isn't a known section.
    func archiveSection(_ name: String) {
        guard sections.contains(name) else { return }
        let archivedAt = Date()
        for index in notes.indices where notes[index].listName == name && notes[index].archivedAt == nil {
            notes[index].archivedAt = archivedAt
        }
        sections.removeAll { $0 == name }
        if activeSection == name {
            activeSection = nil
        }
        scheduleSave()
    }

    /// Reorders `sections` by moving `name` one slot toward `offset` (`-1`
    /// up, `+1` down), swapping with its immediate neighbor. No-op if `name`
    /// isn't a known section or the move would go past either edge.
    func moveSection(_ name: String, offset: Int) {
        guard let index = sections.firstIndex(of: name) else { return }
        let newIndex = index + offset
        guard sections.indices.contains(newIndex) else { return }
        sections.swapAt(index, newIndex)
        scheduleSave()
    }

    /// Archives done notes into the Logbook (Things-style): nothing is
    /// deleted, the notes just leave the list. Scoped to the active section
    /// if one is set, otherwise clears done notes across every section (and
    /// ungrouped).
    func clearDone() {
        guard let activeSection else {
            archiveNotes(matching: { $0.isDone && $0.archivedAt == nil })
            return
        }
        clearDone(in: activeSection)
    }

    /// Clears done notes in `sectionName` specifically, regardless of
    /// whatever section (if any) is currently active — unlike `clearDone()`,
    /// which is scoped to `activeSection`. Used by the section header's
    /// context menu, where "Clear Done in Section" should act on the section
    /// under the cursor even when a different section (or Show All) is
    /// focused.
    func clearDone(in sectionName: String) {
        archiveNotes { $0.isDone && $0.archivedAt == nil && $0.listName == sectionName }
    }

    /// The note row's "Move to Logbook" / ⌥⌫: archives exactly the given
    /// notes, done or not — the per-note counterpart to `clearDone`, which is
    /// scoped by done state instead of by id. Only live notes are touched; a
    /// note already in the Logbook keeps its original `archivedAt`. No-op if
    /// `ids` is empty or none of them are live.
    func archive(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        archiveNotes { ids.contains($0.id) && $0.archivedAt == nil }
    }

    /// Shared logic for `clearDone()`, `clearDone(in:)`, and `archive(ids:)`:
    /// stamps `archivedAt` on every note matching `predicate`. The notes stay
    /// in `notes` (so the launch-time attachment sweep still sees their ids)
    /// and their attachment files stay on disk — the Logbook can put any of
    /// them back.
    private func archiveNotes(matching predicate: (Note) -> Bool) {
        let archivedAt = Date()
        var didArchive = false
        for index in notes.indices where predicate(notes[index]) {
            notes[index].archivedAt = archivedAt
            didArchive = true
        }
        guard didArchive else { return }
        scheduleSave()
    }

    /// The Logbook's "Put Back": clears `archivedAt` so these notes rejoin
    /// the list, keeping their done state. A note whose section has been
    /// deleted or renamed away in the meantime comes back ungrouped, the way
    /// `dissolveSection` leaves notes.
    func restore(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var didRestore = false
        for index in notes.indices where ids.contains(notes[index].id) && notes[index].archivedAt != nil {
            notes[index].archivedAt = nil
            if let listName = notes[index].listName, !sections.contains(listName) {
                notes[index].listName = nil
            }
            didRestore = true
        }
        guard didRestore else { return }
        scheduleSave()
    }

    /// The Logbook's "Delete Permanently": the same removal as any other
    /// note deletion, attachment directories included. Named separately from
    /// `delete(ids:)` so the call site reads as the irreversible action it is.
    func deletePermanently(ids: Set<UUID>) {
        delete(ids: ids)
    }

    /// Joins the text of the given notes (in note order, separated by a blank
    /// line) into the earliest (first-created) note, deleting the others.
    /// Attachments follow the same way: the donor notes' files are physically
    /// moved on disk into the survivor's attachments directory (an
    /// attachment's location is derived from its owning note's id, so
    /// "keeping" it across a merge means relocating the file, not just
    /// editing the in-memory array), then appended to the survivor's list.
    func merge(ids: Set<UUID>) {
        guard ids.count > 1 else { return }
        // Visible order: the notes array IS the display order (drag reorder
        // edits it), so the merged text must read top-to-bottom as the user
        // saw it.
        let inVisibleOrder = notes.filter { ids.contains($0.id) }
        // The earliest-created note survives: its id anchors the on-disk
        // attachments directory, so keeping it avoids relocating the
        // survivor's own files.
        guard let first = inVisibleOrder.min(by: { $0.createdAt < $1.createdAt }),
              let firstIndex = notes.firstIndex(where: { $0.id == first.id }) else {
            return
        }
        let donors = inVisibleOrder.filter { $0.id != first.id }

        let mergedText = inVisibleOrder.map(\.text).joined(separator: "\n\n")
        notes[firstIndex].text = mergedText

        var movedByDonor: [UUID: [Attachment]] = [:]
        for donor in donors where !donor.attachments.isEmpty {
            movedByDonor[donor.id] = moveAttachmentFiles(of: donor, intoNoteDirectoryFor: first.id)
        }
        notes[firstIndex].attachments += donors.flatMap { movedByDonor[$0.id] ?? [] }

        let idsToRemove = Set(donors.map(\.id))
        notes.removeAll { idsToRemove.contains($0.id) }
        for donor in donors {
            let moved = movedByDonor[donor.id] ?? []
            if moved.count == donor.attachments.count {
                removeAttachmentsDirectory(forNoteID: donor.id)
            } else {
                NSLog("NoteStore: leaving attachment directory for \(donor.id) in place; \(donor.attachments.count - moved.count) file(s) failed to move")
            }
        }
        scheduleSave()
    }

    // MARK: - Attachments

    /// Directory holding each note's attachment files, one subdirectory per
    /// note (named by the note's id). Derived from `fileURL`'s parent rather
    /// than hardcoded to Application Support, so the `NICKEL_STORE_PATH` dev
    /// override keeps a note's JSON and its attachments together.
    var attachmentsDirectory: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("Attachments", isDirectory: true)
    }

    /// The on-disk location of `attachment`, inside `note`'s attachment
    /// subdirectory. The attachment id is prefixed onto the filename so two
    /// attachments in the same note can never collide even if picked with
    /// identical original names.
    func url(for attachment: Attachment, in note: Note) -> URL {
        attachmentsDirectory
            .appendingPathComponent(note.id.uuidString, isDirectory: true)
            .appendingPathComponent(attachmentFilename(attachment))
    }

    private func attachmentFilename(_ attachment: Attachment) -> String {
        "\(attachment.id.uuidString)-\(attachment.filename)"
    }

    private func removeAttachmentsDirectory(forNoteID noteID: UUID) {
        let directory = attachmentsDirectory.appendingPathComponent(noteID.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            NSLog("NoteStore: failed to remove attachments directory for \(noteID): \(error)")
        }
    }

    /// Physically moves every attachment file belonging to `donor` into
    /// `noteID`'s attachments directory (creating it on demand). Used by
    /// `merge`: an attachment's path is derived from its owning note's id, so
    /// reassigning it to a different note means relocating the file, not
    /// just editing the in-memory `Attachment` array.
    private func moveAttachmentFiles(of donor: Note, intoNoteDirectoryFor noteID: UUID) -> [Attachment] {
        let destinationDirectory = attachmentsDirectory.appendingPathComponent(noteID.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        } catch {
            NSLog("NoteStore: failed to create attachments directory while merging: \(error)")
            return []
        }
        var moved: [Attachment] = []
        for attachment in donor.attachments {
            let source = url(for: attachment, in: donor)
            let destination = destinationDirectory.appendingPathComponent(attachmentFilename(attachment))
            do {
                try FileManager.default.moveItem(at: source, to: destination)
                moved.append(attachment)
            } catch {
                NSLog("NoteStore: failed to move attachment \"\(attachment.filename)\" during merge: \(error)")
            }
        }
        return moved
    }

    /// Deletes any `Attachments/<note-id>` directory whose note no longer
    /// exists. Guards against orphaned files left behind if the app quit or
    /// crashed between copying an attachment's file and saving the note that
    /// references it.
    private func sweepOrphanedAttachmentDirectories() {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: attachmentsDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        let knownNoteIDs = Set(notes.map { $0.id.uuidString })
        for entry in entries where !knownNoteIDs.contains(entry.lastPathComponent) {
            do {
                try fileManager.removeItem(at: entry)
            } catch {
                NSLog("NoteStore: failed to remove orphaned attachments directory \(entry.lastPathComponent): \(error)")
            }
        }
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let now = Date()
        if firstPendingSaveAt == nil { firstPendingSaveAt = now }
        let delay = Self.nextSaveDelay(firstPendingAt: firstPendingSaveAt, now: now, debounce: saveDebounceInterval, maxDeferral: maxSaveDeferral)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let envelope = StoredEnvelope(version: 2, sections: self.sections, activeSection: self.activeSection, notes: self.notes)
            self.saveWorkItem = nil
            self.firstPendingSaveAt = nil
            self.saveQueue.async {
                self.write(envelope)
            }
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// The delay the next debounced save should use: the normal debounce
    /// interval, shortened so the write lands no later than `maxDeferral`
    /// after `firstPendingAt`. Never negative.
    static func nextSaveDelay(firstPendingAt: Date?, now: Date, debounce: TimeInterval, maxDeferral: TimeInterval) -> TimeInterval {
        guard let firstPendingAt else { return debounce }
        let ceilingRemaining = maxDeferral - now.timeIntervalSince(firstPendingAt)
        return max(0, min(debounce, ceilingRemaining))
    }

    /// Writes the current notes to disk immediately, bypassing the debounce.
    /// Safe to call from `applicationWillTerminate`. Snapshots the envelope
    /// on the caller's thread, then fences the write behind any in-flight
    /// async save on `saveQueue` (a serial queue), so the last write on
    /// return is always this snapshot.
    func saveNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        firstPendingSaveAt = nil

        let envelope = StoredEnvelope(version: 2, sections: sections, activeSection: activeSection, notes: notes)
        saveQueue.sync {
            self.write(envelope)
        }
    }

    /// Encodes and writes a snapshotted envelope to disk. Only ever called
    /// on `saveQueue`.
    private func write(_ envelope: StoredEnvelope) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

            let data = try Self.makeEncoder().encode(envelope)
            try data.write(to: fileURL, options: .atomic)

            // Attributes on createDirectory only apply when the directory is newly
            // created, and .atomic writes via a temp file + rename so the mode never
            // carries over from a prior chmod. Reapply both after every write; a
            // chmod failure must never fail the save, so these are best-effort.
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

            if saveError != nil {
                DispatchQueue.main.async { self.saveError = nil }
            }
        } catch {
            NSLog("NoteStore: failed to save notes: \(error)")
            DispatchQueue.main.async { self.saveError = error.localizedDescription }
        }
    }

    /// On-disk envelope format (version 2): explicit sections and the active
    /// section alongside the notes themselves. `Note.listName` is unchanged
    /// (still the JSON key) for backward compatibility with version 1 files.
    private struct StoredEnvelope: Codable {
        var version: Int
        var sections: [String]
        var activeSection: String?
        var notes: [Note]
    }

    private struct Loaded {
        var notes: [Note]
        var sections: [String]
        var activeSection: String?
        /// False when the on-disk file exists but couldn't be read or
        /// decoded, so `notes` is empty as a fallback rather than a true
        /// reflection of "no notes exist." Callers must not treat a dirty
        /// load as authoritative for anything destructive (e.g. sweeping
        /// "orphaned" attachment directories).
        var loadedCleanly: Bool = true
    }

    private static func load(from url: URL) -> Loaded {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Loaded(notes: [], sections: [], activeSection: nil)
        }

        guard let data = try? Data(contentsOf: url) else {
            NSLog("NoteStore: notes file could not be read, moving aside")
            moveCorruptFileAside(url)
            return Loaded(notes: [], sections: [], activeSection: nil, loadedCleanly: false)
        }

        let decoder = makeDecoder()

        // Current (version 2) envelope format.
        if let envelope = try? decoder.decode(StoredEnvelope.self, from: data) {
            return repaired(notes: envelope.notes, sections: envelope.sections, activeSection: envelope.activeSection)
        }

        // Legacy format: a bare array of notes, with sections only implicit
        // in `listName`. Migrate: sections become the distinct listNames in
        // first-appearance order; no section is active.
        if let legacyNotes = try? decoder.decode([Note].self, from: data) {
            let sections = distinctListNames(in: legacyNotes)
            return repaired(notes: legacyNotes, sections: sections, activeSection: nil)
        }

        NSLog("NoteStore: notes file is corrupt, moving aside")
        moveCorruptFileAside(url)
        return Loaded(notes: [], sections: [], activeSection: nil, loadedCleanly: false)
    }

    /// Distinct non-nil list names, in first-appearance order.
    private static func distinctListNames(in notes: [Note]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for note in notes {
            guard let listName = note.listName, !seen.contains(listName) else { continue }
            seen.insert(listName)
            result.append(listName)
        }
        return result
    }

    /// Repairs a just-loaded envelope: any note whose `listName` isn't in
    /// `sections` gets its listName appended to `sections` (so no note is
    /// ever silently orphaned from the section list), and `activeSection` is
    /// reset to nil if it no longer names a known section.
    ///
    /// Archived notes are ignored here: they're not shown in the list, and
    /// one that was cleared from a since-deleted section must not bring that
    /// section back at the next launch.
    private static func repaired(notes: [Note], sections: [String], activeSection: String?) -> Loaded {
        var repairedSections = sections
        let live = notes.filter { $0.archivedAt == nil }
        for listName in distinctListNames(in: live) where !repairedSections.contains(listName) {
            repairedSections.append(listName)
        }

        let repairedActiveSection = activeSection.flatMap { repairedSections.contains($0) ? $0 : nil }

        return Loaded(notes: notes, sections: repairedSections, activeSection: repairedActiveSection)
    }

    /// Moves an unreadable/corrupt notes file aside rather than losing it.
    /// Each call gets a unique, timestamped backup name (`notes-corrupt-
    /// <timestamp>.json`, with a numeric suffix if that exact name is
    /// somehow already taken) so repeated failures never overwrite an
    /// earlier backup — the only surviving copy of a user's notes must never
    /// be silently destroyed.
    private static func moveCorruptFileAside(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        let fileManager = FileManager.default

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let timestamp = formatter.string(from: Date())

        var backupURL = directory.appendingPathComponent("notes-corrupt-\(timestamp).json")
        var suffix = 2
        while fileManager.fileExists(atPath: backupURL.path) {
            backupURL = directory.appendingPathComponent("notes-corrupt-\(timestamp)-\(suffix).json")
            suffix += 1
        }

        do {
            try fileManager.moveItem(at: url, to: backupURL)
        } catch {
            NSLog("NoteStore: failed to move corrupt notes file aside: \(error)")
        }
    }

    private static func defaultFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Nickel", isDirectory: true).appendingPathComponent("notes.json")
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

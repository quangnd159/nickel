import Foundation

/// Persistent store of notes, backed by a JSON file in Application Support.
/// Mutations are applied synchronously in memory and saved to disk on a short
/// debounce so rapid edits don't thrash the filesystem.
final class NoteStore: ObservableObject {
    @Published private(set) var notes: [Note]

    /// Explicit sections (Copper-style groups), in display order. This is now
    /// the source of truth for a section's existence and ordering — it can
    /// contain sections with no notes in them yet, unlike the old
    /// notes-derived `listNames`.
    @Published private(set) var sections: [String]

    /// The section notes are currently captured into, and the panel's
    /// focused view when non-nil. `nil` means "Show All".
    @Published private(set) var activeSection: String?

    let fileURL: URL
    private var saveWorkItem: DispatchWorkItem?
    private let saveDebounceInterval: TimeInterval = 0.5
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

        // A failed/corrupt load leaves `notes` empty without those notes
        // actually being gone (see `load`'s failure paths), so sweeping now
        // would delete every attachment directory as "orphaned." Only sweep
        // when the load genuinely reflects what's on disk.
        if loaded.loadedCleanly {
            sweepOrphanedAttachmentDirectories()
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
    func add(text: String, attachments: [(sourceURL: URL, filename: String, contentType: String)], sourceApp: String?) {
        let noteID = UUID()
        let savedAttachments = copyAttachments(attachments, intoNoteDirectoryFor: noteID)

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
    }

    /// Copies each `(sourceURL, filename, contentType)` input into
    /// `noteID`'s attachments directory (creating it on demand), returning
    /// the `Attachment`s that copied successfully.
    private func copyAttachments(
        _ inputs: [(sourceURL: URL, filename: String, contentType: String)],
        intoNoteDirectoryFor noteID: UUID
    ) -> [Attachment] {
        guard !inputs.isEmpty else { return [] }

        let destinationDirectory = attachmentsDirectory.appendingPathComponent(noteID.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        } catch {
            NSLog("NoteStore: failed to create attachments directory: \(error)")
            return []
        }

        var saved: [Attachment] = []
        for input in inputs {
            let attachment = Attachment(id: UUID(), filename: input.filename, contentType: input.contentType)
            let destination = destinationDirectory.appendingPathComponent(attachmentFilename(attachment))
            do {
                try FileManager.default.copyItem(at: input.sourceURL, to: destination)
                saved.append(attachment)
            } catch {
                NSLog("NoteStore: failed to copy attachment \"\(input.filename)\": \(error)")
            }
        }
        return saved
    }

    func update(id: UUID, text: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].text = text
        scheduleSave()
    }

    func toggleDone(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for index in notes.indices where ids.contains(notes[index].id) {
            notes[index].isDone.toggle()
        }
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
        if let sectionName, !sections.contains(sectionName) {
            sections.append(sectionName)
        }
        for index in notes.indices where ids.contains(notes[index].id) {
            notes[index].listName = sectionName
        }
        scheduleSave()
    }

    /// Renames every note in section `oldName` to `newName`, and updates the
    /// `sections` entry (and `activeSection`, if it pointed at `oldName`) to
    /// match. If `newName` (case-insensitively) matches an already-existing
    /// section, the two merge under that existing section's casing. Trims
    /// whitespace; a blank result after trimming is a no-op (Finder leaves
    /// the name unchanged rather than allowing an empty folder name).
    func renameSection(from oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName else { return }

        // If an existing (different) section already has this name
        // case-insensitively, merge into it using its existing casing.
        let canonicalName = sections.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame } ?? trimmed

        guard canonicalName != oldName else { return }

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
    func dissolveSection(_ name: String) {
        let ids = Set(notes.filter { $0.listName == name }.map(\.id))
        for index in notes.indices where ids.contains(notes[index].id) {
            notes[index].listName = nil
        }
        sections.removeAll { $0 == name }
        if activeSection == name {
            activeSection = nil
        }
        scheduleSave()
    }

    /// Deletes `name` and every note in it — the opposite of `dissolveSection`,
    /// which keeps the notes. Routed through `delete(ids:)` so attachment
    /// directories are cleaned up like any other note deletion. No-op if
    /// `name` isn't a known section.
    func deleteSection(_ name: String) {
        guard sections.contains(name) else { return }
        let ids = Set(notes.filter { $0.listName == name }.map(\.id))
        if !ids.isEmpty {
            delete(ids: ids)
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

    /// Deletes done notes. Scoped to the active section if one is set,
    /// otherwise clears done notes across every section (and ungrouped).
    func clearDone() {
        guard let activeSection else {
            removeDoneNotes(matching: \.isDone)
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
        removeDoneNotes { $0.isDone && $0.listName == sectionName }
    }

    /// Shared removal logic for `clearDone()` and `clearDone(in:)`: deletes
    /// every note matching `predicate` and its attachments directory.
    private func removeDoneNotes(matching predicate: (Note) -> Bool) {
        let toRemove = notes.filter(predicate)
        guard !toRemove.isEmpty else { return }
        notes.removeAll(where: predicate)
        for note in toRemove {
            removeAttachmentsDirectory(forNoteID: note.id)
        }
        scheduleSave()
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
        let targets = notes.filter { ids.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
        guard let first = targets.first, let firstIndex = notes.firstIndex(where: { $0.id == first.id }) else {
            return
        }
        let donors = targets.dropFirst()

        let mergedText = targets.map(\.text).joined(separator: "\n\n")
        notes[firstIndex].text = mergedText

        for donor in donors where !donor.attachments.isEmpty {
            moveAttachmentFiles(of: donor, intoNoteDirectoryFor: first.id)
        }
        notes[firstIndex].attachments += donors.flatMap(\.attachments)

        let idsToRemove = Set(donors.map(\.id))
        notes.removeAll { idsToRemove.contains($0.id) }
        for donor in donors {
            removeAttachmentsDirectory(forNoteID: donor.id)
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
    private func moveAttachmentFiles(of donor: Note, intoNoteDirectoryFor noteID: UUID) {
        let destinationDirectory = attachmentsDirectory.appendingPathComponent(noteID.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        } catch {
            NSLog("NoteStore: failed to create attachments directory while merging: \(error)")
            return
        }
        for attachment in donor.attachments {
            let source = url(for: attachment, in: donor)
            let destination = destinationDirectory.appendingPathComponent(attachmentFilename(attachment))
            do {
                try FileManager.default.moveItem(at: source, to: destination)
            } catch {
                NSLog("NoteStore: failed to move attachment \"\(attachment.filename)\" during merge: \(error)")
            }
        }
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
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let envelope = StoredEnvelope(version: 2, sections: self.sections, activeSection: self.activeSection, notes: self.notes)
            self.saveWorkItem = nil
            self.saveQueue.async {
                self.write(envelope)
            }
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounceInterval, execute: workItem)
    }

    /// Writes the current notes to disk immediately, bypassing the debounce.
    /// Safe to call from `applicationWillTerminate`. Snapshots the envelope
    /// on the caller's thread, then fences the write behind any in-flight
    /// async save on `saveQueue` (a serial queue), so the last write on
    /// return is always this snapshot.
    func saveNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil

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
        } catch {
            NSLog("NoteStore: failed to save notes: \(error)")
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
    private static func repaired(notes: [Note], sections: [String], activeSection: String?) -> Loaded {
        var repairedSections = sections
        for listName in distinctListNames(in: notes) where !repairedSections.contains(listName) {
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

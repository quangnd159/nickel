import Foundation

/// Persistent store of notes, backed by a JSON file in Application Support.
/// Mutations are applied synchronously in memory and saved to disk on a short
/// debounce so rapid edits don't thrash the filesystem.
final class NoteStore: ObservableObject {
    @Published private(set) var notes: [Note]

    /// Distinct non-nil list names, in first-appearance order.
    var listNames: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for note in notes {
            guard let listName = note.listName, !seen.contains(listName) else { continue }
            seen.insert(listName)
            result.append(listName)
        }
        return result
    }

    private let fileURL: URL
    private var saveWorkItem: DispatchWorkItem?
    private let saveDebounceInterval: TimeInterval = 0.5

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.notes = Self.load(from: self.fileURL)
    }

    // MARK: - Mutations

    func add(text: String, sourceApp: String?) {
        let note = Note(
            id: UUID(),
            text: text,
            listName: nil,
            isDone: false,
            createdAt: Date(),
            sourceApp: sourceApp
        )
        notes.append(note)
        scheduleSave()
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
        notes.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    func move(ids: Set<UUID>, toList listName: String?) {
        guard !ids.isEmpty else { return }
        for index in notes.indices where ids.contains(notes[index].id) {
            notes[index].listName = listName
        }
        scheduleSave()
    }

    /// Joins the text of the given notes (in note order, separated by a blank
    /// line) into the earliest (first-created) note, deleting the others.
    func merge(ids: Set<UUID>) {
        guard ids.count > 1 else { return }
        let targets = notes.filter { ids.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
        guard let first = targets.first, let firstIndex = notes.firstIndex(where: { $0.id == first.id }) else {
            return
        }

        let mergedText = targets.map(\.text).joined(separator: "\n\n")
        notes[firstIndex].text = mergedText

        let idsToRemove = Set(targets.dropFirst().map(\.id))
        notes.removeAll { idsToRemove.contains($0.id) }
        scheduleSave()
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounceInterval, execute: workItem)
    }

    /// Writes the current notes to disk immediately, bypassing the debounce.
    /// Safe to call from `applicationWillTerminate`.
    func saveNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil

        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let data = try Self.makeEncoder().encode(notes)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("NoteStore: failed to save notes: \(error)")
        }
    }

    private static func load(from url: URL) -> [Note] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: url)
            return try makeDecoder().decode([Note].self, from: data)
        } catch {
            NSLog("NoteStore: notes file is corrupt, moving aside: \(error)")
            moveCorruptFileAside(url)
            return []
        }
    }

    private static func moveCorruptFileAside(_ url: URL) {
        let backupURL = url.deletingLastPathComponent().appendingPathComponent("notes.json.bak")
        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
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

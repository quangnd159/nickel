import Foundation

/// Temporary in-memory store for captured text. Milestone 3 replaces this with persistence.
final class CapturedStore: ObservableObject {
    struct Item: Identifiable {
        let id = UUID()
        let text: String
        let app: String?
    }

    @Published private(set) var items: [Item] = []

    func add(text: String, app: String?) {
        items.append(Item(text: text, app: app))
    }
}

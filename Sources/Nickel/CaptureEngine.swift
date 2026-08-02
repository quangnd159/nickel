import AppKit
import ApplicationServices

enum CaptureEngine {
    /// The localized name of the app that would be the source of a capture right now.
    static var frontmostAppName: String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    /// Captures the current text selection from the frontmost app. Tries the
    /// Accessibility API first, then falls back to a ⌘C-via-pasteboard snapshot.
    /// Blocking; call off the main thread.
    static func captureSelectedText() -> String? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return nil
        }

        if let text = captureViaAccessibility(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            debugLog("CaptureEngine: AX path, length=\(trimmed.count)")
            return trimmed
        }

        let text = captureViaPasteboard()
        debugLog("CaptureEngine: pasteboard path, length=\(text.map { String($0.count) } ?? "nil")")
        return text
    }

    private static func captureViaAccessibility() -> String? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement
        ) == .success, let element = focusedElement else {
            return nil
        }

        var selectedText: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedText
        ) == .success else {
            return nil
        }

        return selectedText as? String
    }

    /// How long to wait for the ⌘C copy to land before giving up on the fast path.
    private static let primaryPollWindow: TimeInterval = 1.0
    /// How long to keep watching the pasteboard after restoring the user's
    /// snapshot, to catch a copy that lands late (slow app, remote desktop).
    private static let graceWindow: TimeInterval = 0.5
    private static let pollInterval: TimeInterval = 0.03

    private static func captureViaPasteboard() -> String? {
        let pasteboard = NSPasteboard.general
        let originalChangeCount = pasteboard.changeCount
        let snapshot = snapshotItems(of: pasteboard)

        postCommandC()

        var changed = false
        let deadline = Date().addingTimeInterval(primaryPollWindow)
        while Date() < deadline {
            if pasteboard.changeCount != originalChangeCount {
                changed = true
                break
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }

        var captured = changed ? markdown(from: pasteboard) ?? pasteboard.string(forType: .string) : nil
        restore(snapshot, to: pasteboard)

        if !changed {
            // The copy hasn't landed yet. Keep watching the pasteboard for a
            // grace period even though we already restored the user's
            // snapshot: if a late write arrives, treat it as the capture and
            // restore again so the user's clipboard is preserved. Trade-off:
            // a user-initiated copy performed within this window (right
            // after a failed capture) would be reverted too, which is
            // acceptable since the user just double-tapped the capture shortcut.
            let restoredChangeCount = pasteboard.changeCount
            let graceDeadline = Date().addingTimeInterval(graceWindow)
            while Date() < graceDeadline {
                if pasteboard.changeCount != restoredChangeCount {
                    captured = markdown(from: pasteboard) ?? pasteboard.string(forType: .string)
                    restore(snapshot, to: pasteboard)
                    break
                }
                Thread.sleep(forTimeInterval: pollInterval)
            }
        }

        guard let text = captured?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    /// Prefers a rich pasteboard flavor (HTML, then RTF) converted to
    /// Markdown, so bold/italic/links/lists/etc. survive the capture. Falls
    /// back to nil (letting the caller use the plain-text flavor) when
    /// neither flavor is present or conversion yields nothing.
    private static func markdown(from pasteboard: NSPasteboard) -> String? {
        if let data = pasteboard.data(forType: .html),
           let markdown = MarkdownConverter.markdown(fromHTML: data),
           !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return markdown
        }
        if let data = pasteboard.data(forType: .rtf),
           let markdown = MarkdownConverter.markdown(fromRTF: data),
           !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return markdown
        }
        return nil
    }

    private static func snapshotItems(of pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict
        }
    }

    private static func restore(_ snapshot: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        let items = snapshot.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    private static func postCommandC() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let keyCodeC: CGKeyCode = 8

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeC, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeC, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}

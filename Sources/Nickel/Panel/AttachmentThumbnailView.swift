import SwiftUI
import AppKit
import QuickLookThumbnailing

/// Renders a thumbnail for a file on disk, generated off-main via
/// `QuickLookThumbnailing` and cached (keyed by file location + content type
/// + pixel size) in a shared, process-wide `NSCache` so re-rendering a note
/// (e.g. on selection change) doesn't regenerate the same thumbnail. Falls
/// back to the file type's generic icon while the thumbnail is pending or if
/// generation fails.
///
/// Takes a bare `fileURL` + `contentType` rather than an `Attachment` so it
/// can also front a `StagedAttachment` chip in the composer, which has no
/// committed `Attachment` (and thus no stable `id`) yet.
///
/// This view is purely presentational — it does not itself react to clicks;
/// `NoteRow` owns click handling so a single click still selects the row
/// (see its `attachmentFrames` tracking) and a double-click opens the file.
struct AttachmentThumbnailView: View {
    let fileURL: URL
    let contentType: String
    /// The bounding box, in points, the thumbnail is generated for. Callers
    /// showing it in a fixed square frame pass that square's size; the note
    /// card's big image thumbnail asks for more than it usually draws, since
    /// a wide image comes back short and would otherwise be scaled up.
    var size: CGFloat
    /// How the generated thumbnail fills its frame. `.fill` crops it to a
    /// frame the caller has already sized (every square thumbnail); `.fit`
    /// lets it keep its own shape inside the space offered.
    var contentMode: ContentMode = .fill

    @State private var image: NSImage?

    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: fileURL.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .task(id: cacheKey) { await loadThumbnail() }
    }

    private var cacheKey: String {
        "\(fileURL.path)|\(contentType)@\(Int(size))"
    }

    @MainActor
    private func loadThumbnail() async {
        let key = cacheKey as NSString
        if let cached = Self.cache.object(forKey: key) {
            image = cached
            return
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: CGSize(width: size, height: size),
            scale: scale,
            representationTypes: .thumbnail
        )

        let generated: NSImage? = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
                if let representation {
                    continuation.resume(returning: representation.nsImage)
                } else {
                    if let error {
                        NSLog("AttachmentThumbnailView: thumbnail generation failed for \(fileURL.lastPathComponent): \(error)")
                    }
                    continuation.resume(returning: nil)
                }
            }
        }

        guard let generated else { return }
        Self.cache.setObject(generated, forKey: key)
        // The request may be stale by the time generation completes (e.g. the
        // row was recycled for a different attachment); only apply the
        // result if we're still showing the same one.
        if key == cacheKey as NSString {
            image = generated
        }
    }
}

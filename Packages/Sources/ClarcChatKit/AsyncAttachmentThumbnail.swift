import AppKit
import SwiftUI

@MainActor
private final class AttachmentThumbnailCache {
    static let shared = AttachmentThumbnailCache()
    private let images = NSCache<NSString, NSImage>()

    private init() {
        images.countLimit = 96
        images.totalCostLimit = 24 * 1_024 * 1_024
    }

    func image(for path: String) -> NSImage? {
        images.object(forKey: path as NSString)
    }

    func insert(_ image: NSImage, for path: String, cost: Int) {
        images.setObject(image, forKey: path as NSString, cost: cost)
    }
}

/// Loads attachment bytes away from the main actor, then creates and caches the
/// AppKit image on the main actor. Message rows entering the lazy stack no longer
/// perform synchronous disk I/O in `body`.
struct AsyncAttachmentThumbnail: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    ClaudeTheme.surfaceSecondary
                    Image(systemName: "photo")
                        .font(.system(size: ClaudeTheme.messageSize(13)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        .task(id: path) {
            if let cached = AttachmentThumbnailCache.shared.image(for: path) {
                image = cached
                return
            }

            let fileURL = URL(fileURLWithPath: path)
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: fileURL, options: [.mappedIfSafe])
            }.value
            guard !Task.isCancelled,
                  let data,
                  let loaded = NSImage(data: data) else { return }
            AttachmentThumbnailCache.shared.insert(loaded, for: path, cost: data.count)
            image = loaded
        }
    }
}

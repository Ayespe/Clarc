import AppKit
import ClarcCore
import ImageIO
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

private struct DecodedAttachmentThumbnail: @unchecked Sendable {
    let image: CGImage
    let cost: Int
}

private enum AttachmentThumbnailDecoder {
    /// ImageIO creates a small decoded bitmap directly from the file. This avoids
    /// reading and decoding a full-resolution attachment merely to draw 40 points.
    nonisolated static func decode(path: String, maxPixelSize: Int) async -> DecodedAttachmentThumbnail? {
        await Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return nil }

            let url = URL(fileURLWithPath: path) as CFURL
            let sourceOptions: [CFString: Any] = [
                kCGImageSourceShouldCache: false,
            ]
            guard let source = CGImageSourceCreateWithURL(url, sourceOptions as CFDictionary) else {
                return nil
            }

            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard !Task.isCancelled,
                  let image = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    thumbnailOptions as CFDictionary
                  ) else {
                return nil
            }

            // The cache budget tracks the decoded bitmap rather than compressed
            // file bytes, which is the memory actually retained by the CGImage.
            let (pixelCount, overflow) = image.width.multipliedReportingOverflow(by: image.height)
            let (decodedCost, costOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
            let cost = (overflow || costOverflow) ? Int.max : decodedCost
            return DecodedAttachmentThumbnail(image: image, cost: cost)
        }.value
    }
}

/// Loads attachment bytes away from the main actor, then creates and caches the
/// AppKit image on the main actor. Message rows entering the lazy stack no longer
/// perform synchronous disk I/O in `body`.
struct AsyncAttachmentThumbnail: View {
    private static let logicalSide: CGFloat = 40

    let path: String
    @State private var image: NSImage?
    @Environment(\.displayScale) private var displayScale

    private var maxPixelSize: Int {
        max(Int(Self.logicalSide), Int(ceil(Self.logicalSide * displayScale)))
    }

    private var cacheKey: String {
        "\(path)#\(maxPixelSize)"
    }

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
        .frame(width: Self.logicalSide, height: Self.logicalSide)
        .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        .task(id: cacheKey) {
            image = nil
            if let cached = AttachmentThumbnailCache.shared.image(for: cacheKey) {
                image = cached
                return
            }

            guard !Task.isCancelled,
                  let decoded = await AttachmentThumbnailDecoder.decode(
                    path: path,
                    maxPixelSize: maxPixelSize
                  ),
                  !Task.isCancelled else { return }

            let imageSize = NSSize(
                width: CGFloat(decoded.image.width) / displayScale,
                height: CGFloat(decoded.image.height) / displayScale
            )
            let loaded = NSImage(cgImage: decoded.image, size: imageSize)
            AttachmentThumbnailCache.shared.insert(loaded, for: cacheKey, cost: decoded.cost)
            image = loaded
        }
    }
}

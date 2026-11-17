import UIKit
import ImageIO

extension NSAttributedString.Key {
    /// On linked text: the link's target, as stored in the style run.
    static let readerLink = NSAttributedString.Key("Readling.link")
}

/// An image of the book drawn inline in chapter text.
///
/// Its size follows the line it sits on: it keeps its natural size when that
/// fits, shrinks to the text's width otherwise, and never grows taller than a
/// page (in page modes) or about one and a half text widths (when scrolling).
/// Pictures are decoded at the size they are drawn, once, and kept in a cache.
final class ReaderImageAttachment: NSTextAttachment {
    let url: URL

    init(url: URL, alt: String?) {
        self.url = url
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        guard let natural = ReaderImages.pixelSize(of: url) else { return .zero }
        // A page holds the picture whole; when scrolling, a picture may be a little taller than it is wide.
        var limit = CGSize(width: max(1, lineFrag.width), height: max(1, lineFrag.width * 1.6))
        if let container = textContainer, container.size.height < 100_000 {
            limit.height = max(1, container.size.height - 1)
        }
        let fit = min(1, limit.width / natural.width, limit.height / natural.height)
        return CGRect(x: 0, y: 0, width: (natural.width * fit).rounded(.down), height: (natural.height * fit).rounded(.down))
    }

    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> UIImage? {
        ReaderImages.image(at: url, fitting: imageBounds.size, scale: 3)
    }
}

enum ReaderImages {
    nonisolated(unsafe) private static let sizes = NSCache<NSURL, NSValue>()
    nonisolated(unsafe) private static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()
    /// Largest side, in pixels, a picture is ever decoded to.
    private static let maximumPixels: CGFloat = 4_096

    /// The picture's size in pixels as it will be shown (orientation applied), read from its header; nil if it can't be decoded.
    static func pixelSize(of url: URL) -> CGSize? {
        if let cached = sizes.object(forKey: url as NSURL) { return cached.cgSizeValue == .zero ? nil : cached.cgSizeValue }
        var size = CGSize.zero
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
           let height = properties[kCGImagePropertyPixelHeight] as? CGFloat, width > 0, height > 0 {
            // Orientations 5 to 8 are turned a quarter, which swaps the sides.
            let turned = ((properties[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
            size = turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        }
        sizes.setObject(NSValue(cgSize: size), forKey: url as NSURL)
        return size == .zero ? nil : size
    }

    static func image(at url: URL, fitting size: CGSize, scale: CGFloat) -> UIImage? {
        let pixels = min(maximumPixels, ceil(max(size.width, size.height) * scale))
        let key = "\(url.path)|\(Int(pixels))" as NSString
        if let hit = images.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = UIImage(cgImage: decoded, scale: scale, orientation: .up)
        images.setObject(image, forKey: key, cost: decoded.bytesPerRow * decoded.height)
        return image
    }
}

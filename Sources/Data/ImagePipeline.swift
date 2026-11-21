import UIKit
import ImageIO

/// 1.0.5: posters and logos decoded at the size they are shown (not the provider's full size), kept in a memory cache
/// with a size limit that iOS can also empty under memory pressure. Downloads go through URLSession.shared (and its
/// bounded URLCache); a download is cancelled when its cell leaves the screen (SwiftUI cancels the view's task).
/// Can be switched off in «قياسات الأداء» to measure the difference on the same build.
final class ImagePipeline {
    static let shared = ImagePipeline()
    static let key = "img.downsample"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.totalCostLimit = 60 * 1024 * 1024        // decoded bytes
        cache.countLimit = 600
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            self?.cache.removeAllObjects()
        }
    }

    private func key(_ url: URL, _ px: Int) -> NSString { "\(px)|\(url.absoluteString)" as NSString }

    func clearMemory() { cache.removeAllObjects() }

    func cached(_ url: URL, maxPixel: Int) -> UIImage? { cache.object(forKey: key(url, maxPixel)) }

    func load(_ url: URL, maxPixel: Int) async -> UIImage? {
        if let i = cached(url, maxPixel: maxPixel) { return i }
        guard let (data, _) = try? await URLSession.shared.data(from: url), !Task.isCancelled else { return nil }
        let img = await Task.detached(priority: .utility) { Self.downsample(data, maxPixel) }.value
        if let img, let cg = img.cgImage { cache.setObject(img, forKey: key(url, maxPixel), cost: cg.bytesPerRow * cg.height) }
        return img
    }

    static func downsample(_ data: Data, _ maxPixel: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceShouldCacheImmediately: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

import ImageIO
import SwiftUI
import UIKit

@MainActor
final class MealThumbnailCache {
    static let shared = MealThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()
    private let imageStorage: any ImageStorageProviding
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init() {
        imageStorage = FileImageStorage()
        cache.totalCostLimit = 24 * 1_024 * 1_024
        cache.countLimit = 160
    }

    init(imageStorage: any ImageStorageProviding) {
        self.imageStorage = imageStorage
        cache.totalCostLimit = 24 * 1_024 * 1_024
        cache.countLimit = 160
    }

    func image(
        for storageKey: String,
        displaySize: CGFloat,
        displayScale: CGFloat
    ) async -> UIImage? {
        let pixelSize = max(Int((displaySize * displayScale).rounded(.up)), 1)
        let cacheKey = "\(storageKey)#\(pixelSize)"
        if let cached = cache.object(forKey: cacheKey as NSString) {
            return cached
        }
        if let existing = inFlight[cacheKey] {
            return await existing.value
        }

        let storage = imageStorage
        let task = Task<UIImage?, Never> {
            guard let data = try? await storage.data(forStorageKey: storageKey) else { return nil }
            return await Self.decode(data, maximumPixelSize: pixelSize)
        }
        inFlight[cacheKey] = task
        let image = await task.value
        inFlight[cacheKey] = nil
        if let image {
            cache.setObject(
                image,
                forKey: cacheKey as NSString,
                cost: Int(image.size.width * image.scale * image.size.height * image.scale * 4)
            )
        }
        return image
    }

    nonisolated private static func decode(
        _ data: Data,
        maximumPixelSize: Int
    ) async -> UIImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ) else { return nil }
            return UIImage(cgImage: image)
        }.value
    }
}

struct StoredMealThumbnailView: View {
    @Environment(\.displayScale) private var displayScale
    let storageKey: String?
    let size: CGFloat

    @State private var image: UIImage?

    init(storageKey: String?, size: CGFloat = 64) {
        self.storageKey = storageKey
        self.size = size
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.secondary.opacity(0.12))
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(.rect(cornerRadius: 12))
                } else {
                    Image(systemName: storageKey == nil ? "fork.knife" : "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .task(id: storageKey) {
                image = nil
                guard let storageKey else { return }
                image = await MealThumbnailCache.shared.image(
                    for: storageKey,
                    displaySize: size,
                    displayScale: displayScale
                )
            }
            .accessibilityHidden(true)
    }
}

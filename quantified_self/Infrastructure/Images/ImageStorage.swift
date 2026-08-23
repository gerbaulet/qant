import Foundation
import ImageIO
import OSLog
import UIKit

struct StoredMealImage: Sendable, Equatable {
    let id: UUID
    let imageStorageKey: String
    let thumbnailStorageKey: String
    let pixelWidth: Int
    let pixelHeight: Int
}

protocol ImageStorageProviding {
    func storeImageData(_ data: Data, id: UUID) async throws -> StoredMealImage
    func data(forStorageKey storageKey: String) async throws -> Data
    func deleteImage(_ image: StoredMealImage) async
}

enum ImageStorageError: Error, LocalizedError {
    case invalidImage
    case invalidStorageKey
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "Das ausgewählte Bild konnte nicht gelesen werden."
        case .invalidStorageKey:
            "Der gespeicherte Bildverweis ist ungültig."
        case .encodingFailed:
            "Das Bild konnte nicht verarbeitet werden."
        }
    }
}

struct FileImageStorage: ImageStorageProviding, Sendable {
    nonisolated static let maximumImageDimension = 2_048
    nonisolated static let maximumThumbnailDimension = 320

    private let rootDirectory: URL

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory
    }

    func storeImageData(_ data: Data, id: UUID = UUID()) async throws -> StoredMealImage {
        let rootDirectory = rootDirectory
        return try await Task.detached(priority: .userInitiated) {
            try Self.storeImageData(data, id: id, rootDirectory: rootDirectory)
        }.value
    }

    func data(forStorageKey storageKey: String) async throws -> Data {
        let fileURL = try storageURL(for: storageKey)
        return try await Task.detached(priority: .utility) {
            try Data(contentsOf: fileURL, options: .mappedIfSafe)
        }.value
    }

    func deleteImage(_ image: StoredMealImage) async {
        guard let imageURL = try? storageURL(for: image.imageStorageKey) else { return }
        let directory = imageURL.deletingLastPathComponent()
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }.value
    }

    private func storageURL(for key: String) throws -> URL {
        let root = rootDirectory.standardizedFileURL
        let candidate = root.appending(path: key).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw ImageStorageError.invalidStorageKey
        }
        return candidate
    }

    private static var defaultRootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MealImages", directoryHint: .isDirectory)
    }

    private nonisolated static func storeImageData(
        _ data: Data,
        id: UUID,
        rootDirectory: URL
    ) throws -> StoredMealImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageStorageError.invalidImage
        }

        let fullImage = try makeThumbnail(
            from: source,
            maximumDimension: maximumImageDimension
        )
        let thumbnail = try makeThumbnail(
            from: source,
            maximumDimension: maximumThumbnailDimension
        )

        guard
            let fullData = UIImage(cgImage: fullImage).jpegData(compressionQuality: 0.82),
            let thumbnailData = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.72)
        else {
            throw ImageStorageError.encodingFailed
        }

        let directory = rootDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
        let imageURL = directory.appending(path: "image.jpg")
        let thumbnailURL = directory.appending(path: "thumbnail.jpg")

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try fullData.write(to: imageURL, options: .atomic)
            try thumbnailData.write(to: thumbnailURL, options: .atomic)
            AppLogger.imageStorage.info("Meal image and thumbnail stored")
        } catch {
            try? FileManager.default.removeItem(at: directory)
            AppLogger.imageStorage.error("Meal image storage failed")
            throw error
        }

        return StoredMealImage(
            id: id,
            imageStorageKey: "\(id.uuidString)/image.jpg",
            thumbnailStorageKey: "\(id.uuidString)/thumbnail.jpg",
            pixelWidth: fullImage.width,
            pixelHeight: fullImage.height
        )
    }

    private nonisolated static func makeThumbnail(
        from source: CGImageSource,
        maximumDimension: Int
    ) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageStorageError.invalidImage
        }
        return image
    }
}

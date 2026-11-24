import Foundation
import Testing
import UIKit
@testable import Quant

struct ImageStorageTests {
    @Test("Image storage creates a reduced original and list thumbnail")
    func storesReducedImageAndThumbnail() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = FileImageStorage(rootDirectory: root)
        let id = UUID()

        let stored = try await storage.storeImageData(
            makeJPEGData(size: CGSize(width: 5_000, height: 2_500)),
            id: id
        )

        #expect(stored.id == id)
        #expect(stored.pixelWidth == 4_096)
        #expect(stored.pixelHeight == 2_048)
        #expect(stored.imageStorageKey == "\(id.uuidString)/image.jpg")
        #expect(stored.thumbnailStorageKey == "\(id.uuidString)/thumbnail.jpg")

        let fullData = try await storage.data(forStorageKey: stored.imageStorageKey)
        let thumbnailData = try await storage.data(forStorageKey: stored.thumbnailStorageKey)
        #expect(UIImage(data: fullData)?.size == CGSize(width: 4_096, height: 2_048))
        #expect(UIImage(data: thumbnailData)?.size == CGSize(width: 320, height: 160))

        await storage.deleteImage(stored)
        await #expect(throws: Error.self) {
            try await storage.data(forStorageKey: stored.imageStorageKey)
        }
    }

    @Test("Invalid image data is rejected without creating files")
    func rejectsInvalidImage() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = FileImageStorage(rootDirectory: root)

        await #expect(throws: ImageStorageError.self) {
            try await storage.storeImageData(Data("not an image".utf8), id: UUID())
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Duplicating an image creates independently deletable files")
    func duplicatesImageIndependently() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = FileImageStorage(rootDirectory: root)
        let original = try await storage.storeImageData(
            makeJPEGData(size: CGSize(width: 800, height: 600)),
            id: UUID()
        )

        let duplicate = try await storage.duplicateImage(original)

        #expect(duplicate.id != original.id)
        #expect(duplicate.imageStorageKey != original.imageStorageKey)
        #expect(duplicate.pixelWidth == original.pixelWidth)
        #expect(duplicate.pixelHeight == original.pixelHeight)
        let originalData = try await storage.data(forStorageKey: original.imageStorageKey)
        let duplicateData = try await storage.data(forStorageKey: duplicate.imageStorageKey)
        let originalThumbnail = try await storage.data(forStorageKey: original.thumbnailStorageKey)
        let duplicateThumbnail = try await storage.data(forStorageKey: duplicate.thumbnailStorageKey)
        #expect(duplicateData == originalData)
        #expect(duplicateThumbnail == originalThumbnail)

        await storage.deleteImage(original)
        #expect(try await storage.data(forStorageKey: duplicate.imageStorageKey).isEmpty == false)
    }

    @Test("Storage keys cannot escape the image directory")
    func rejectsUnsafeStorageKey() async {
        let storage = FileImageStorage(rootDirectory: temporaryRoot())

        await #expect(throws: ImageStorageError.self) {
            try await storage.data(forStorageKey: "../private.jpg")
        }
    }

    @MainActor
    @Test("Thumbnail cache reuses a decoded image after the file is removed")
    func thumbnailCache() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = FileImageStorage(rootDirectory: root)
        let stored = try await storage.storeImageData(
            makeJPEGData(size: CGSize(width: 800, height: 600)),
            id: UUID()
        )
        let cache = MealThumbnailCache(imageStorage: storage)

        let first = try #require(await cache.image(
            for: stored.thumbnailStorageKey,
            displaySize: 64,
            displayScale: 2
        ))
        await storage.deleteImage(stored)
        let second = try #require(await cache.image(
            for: stored.thumbnailStorageKey,
            displaySize: 64,
            displayScale: 2
        ))

        #expect(first === second)
        #expect(first.size.width <= 128)
        #expect(first.size.height <= 128)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "quantified-self-image-tests-\(UUID().uuidString)")
    }

    private func makeJPEGData(size: CGSize) -> Data {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
        }
        return image.jpegData(compressionQuality: 0.95)!
    }
}

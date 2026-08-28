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
            makeJPEGData(size: CGSize(width: 2_400, height: 1_200)),
            id: id
        )

        #expect(stored.id == id)
        #expect(stored.pixelWidth == 2_048)
        #expect(stored.pixelHeight == 1_024)
        #expect(stored.imageStorageKey == "\(id.uuidString)/image.jpg")
        #expect(stored.thumbnailStorageKey == "\(id.uuidString)/thumbnail.jpg")

        let fullData = try await storage.data(forStorageKey: stored.imageStorageKey)
        let thumbnailData = try await storage.data(forStorageKey: stored.thumbnailStorageKey)
        #expect(UIImage(data: fullData)?.size == CGSize(width: 2_048, height: 1_024))
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

    @Test("Storage keys cannot escape the image directory")
    func rejectsUnsafeStorageKey() async {
        let storage = FileImageStorage(rootDirectory: temporaryRoot())

        await #expect(throws: ImageStorageError.self) {
            try await storage.data(forStorageKey: "../private.jpg")
        }
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

import Foundation
import ImageIO
import SwiftUI
import UIKit

struct PendingMealImage: Identifiable {
    let id: UUID
    let data: Data
    let preview: UIImage

    static func prepare(data: Data, id: UUID = UUID()) async throws -> PendingMealImage {
        let preview = try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                throw ImageStorageError.invalidImage
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: FileImageStorage.maximumThumbnailDimension,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ) else {
                throw ImageStorageError.invalidImage
            }
            return image
        }.value
        return PendingMealImage(id: id, data: data, preview: UIImage(cgImage: preview))
    }
}

nonisolated enum CameraCaptureFlow: Equatable {
    case confirmBeforeUsing
    case useImmediately

    static func forCapture(openedFromShortcut: Bool) -> Self {
        openedFromShortcut ? .useImmediately : .confirmBeforeUsing
    }
}

struct PendingMealImageThumbnail: View {
    let image: PendingMealImage
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: image.preview)
                .resizable()
                .scaledToFill()
                .frame(width: 104, height: 104)
                .clipShape(.rect(cornerRadius: 14))
                .accessibilityHidden(true)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.65))
            }
            .frame(minWidth: 44, minHeight: 44)
            .padding(5)
            .accessibilityLabel("Foto entfernen")
        }
    }
}

enum CaptureAlert: Identifiable {
    case imageImportFailed
    case cameraCaptureFailed
    case cameraUnavailable
    case cameraDenied
    case saveFailed

    var id: String {
        switch self {
        case .imageImportFailed: "imageImportFailed"
        case .cameraCaptureFailed: "cameraCaptureFailed"
        case .cameraUnavailable: "cameraUnavailable"
        case .cameraDenied: "cameraDenied"
        case .saveFailed: "saveFailed"
        }
    }

    var title: String {
        switch self {
        case .imageImportFailed: "Foto konnte nicht hinzugefügt werden"
        case .cameraCaptureFailed: "Foto konnte nicht aufgenommen werden"
        case .cameraUnavailable: "Kamera nicht verfügbar"
        case .cameraDenied: "Kein Kamerazugriff"
        case .saveFailed: "Mahlzeit konnte nicht gespeichert werden"
        }
    }

    var message: String {
        switch self {
        case .imageImportFailed:
            "Bitte wähle ein anderes Bild."
        case .cameraCaptureFailed:
            "Bitte versuche die Aufnahme erneut."
        case .cameraUnavailable:
            "Auf diesem Gerät steht keine Kamera zur Verfügung."
        case .cameraDenied:
            "Erlaube den Kamerazugriff in den Einstellungen, um ein Foto aufzunehmen."
        case .saveFailed:
            "Deine Eingabe ist unverändert. Bitte prüfe den freien Speicher und versuche es erneut."
        }
    }

    var offersSettings: Bool {
        if case .cameraDenied = self { return true }
        return false
    }
}

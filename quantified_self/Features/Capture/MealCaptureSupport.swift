import SwiftUI
import UIKit

struct PendingMealImage: Identifiable {
    let id = UUID()
    let data: Data
}

struct PendingMealImageThumbnail: View {
    let image: PendingMealImage
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let uiImage = UIImage(data: image.data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 104, height: 104)
                    .clipShape(.rect(cornerRadius: 14))
                    .accessibilityHidden(true)
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.65))
            }
            .padding(5)
            .accessibilityLabel("Foto entfernen")
        }
    }
}

enum CaptureAlert: Identifiable {
    case imageImportFailed
    case cameraUnavailable
    case cameraDenied
    case saveFailed(String)

    var id: String {
        switch self {
        case .imageImportFailed: "imageImportFailed"
        case .cameraUnavailable: "cameraUnavailable"
        case .cameraDenied: "cameraDenied"
        case .saveFailed: "saveFailed"
        }
    }

    var title: String {
        switch self {
        case .imageImportFailed: "Foto konnte nicht hinzugefügt werden"
        case .cameraUnavailable: "Kamera nicht verfügbar"
        case .cameraDenied: "Kein Kamerazugriff"
        case .saveFailed: "Mahlzeit konnte nicht gespeichert werden"
        }
    }

    var message: String {
        switch self {
        case .imageImportFailed:
            "Bitte wähle ein anderes Bild."
        case .cameraUnavailable:
            "Auf diesem Gerät steht keine Kamera zur Verfügung."
        case .cameraDenied:
            "Erlaube den Kamerazugriff in den Einstellungen, um ein Foto aufzunehmen."
        case .saveFailed(let message):
            message
        }
    }

    var offersSettings: Bool {
        if case .cameraDenied = self { return true }
        return false
    }
}

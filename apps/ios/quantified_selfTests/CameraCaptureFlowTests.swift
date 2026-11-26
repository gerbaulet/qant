import AVFoundation
import Foundation
import Testing
import UIKit
@testable import Quant

struct CameraCaptureFlowTests {
    @Test("Shortcut captures use photos immediately")
    func shortcutUsesPhotoImmediately() {
        #expect(CameraCaptureFlow.forCapture(openedFromShortcut: true) == .useImmediately)
    }

    @Test("Standard captures retain the confirmation step")
    func standardCaptureKeepsConfirmation() {
        #expect(CameraCaptureFlow.forCapture(openedFromShortcut: false) == .confirmBeforeUsing)
    }

    @Test("Immediate capture saves as pending and starts analysis")
    func immediateSaveMode() {
        #expect(MealCaptureSaveMode.analyzeNow.analysisState == .pending)
        #expect(MealCaptureSaveMode.analyzeNow.startsAnalysis)
        #expect(MealCaptureSaveMode.analyzeNow.isAvailable(imageCount: 0))
    }

    @Test("Deferred capture requires a photo and waits for a description")
    func deferredSaveMode() {
        #expect(MealCaptureSaveMode.describeLater.analysisState == .awaitingDescription)
        #expect(!MealCaptureSaveMode.describeLater.startsAnalysis)
        #expect(!MealCaptureSaveMode.describeLater.isAvailable(imageCount: 0))
        #expect(MealCaptureSaveMode.describeLater.isAvailable(imageCount: 1))
    }

    @MainActor
    @Test("Camera captures start with the flash disabled")
    func cameraFlashStartsDisabled() {
        #expect(CameraFlashConfiguration.imagePickerMode == .off)
        #expect(CameraFlashConfiguration.photoSettingsMode == .off)
    }

    @MainActor
    @Test("Pending images prepare a bounded preview once")
    func pendingImagePreview() async throws {
        let size = CGSize(width: 1_200, height: 600)
        let data = try #require(UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.9))

        let pending = try await PendingMealImage.prepare(data: data)

        #expect(pending.data == data)
        #expect(pending.preview.size == CGSize(width: 320, height: 160))
    }

    @MainActor
    @Test("Invalid pending image data is rejected")
    func invalidPendingImage() async {
        await #expect(throws: ImageStorageError.self) {
            try await PendingMealImage.prepare(data: Data("invalid".utf8))
        }
    }
}

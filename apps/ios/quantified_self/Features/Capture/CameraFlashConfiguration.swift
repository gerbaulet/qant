import AVFoundation
import UIKit

@MainActor
enum CameraFlashConfiguration {
    static let imagePickerMode: UIImagePickerController.CameraFlashMode = .off
    static let photoSettingsMode: AVCaptureDevice.FlashMode = .off
}

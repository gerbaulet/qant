import AVFoundation
import OSLog
import SwiftUI
import UIKit

/// A one-tap camera used only by the app shortcut. Unlike UIImagePickerController,
/// it does not add a second system confirmation step after taking the photo.
struct QuickCameraView: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    let onCancel: () -> Void
    let onFailure: () -> Void

    func makeUIViewController(context: Context) -> QuickCameraViewController {
        QuickCameraViewController(
            onCapture: onCapture,
            onCancel: onCancel,
            onFailure: onFailure
        )
    }

    func updateUIViewController(_ uiViewController: QuickCameraViewController, context: Context) {}
}

final class QuickCameraViewController: UIViewController, AVCapturePhotoCaptureDelegate {
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "de.clemensgerbaulet.quant.quick-camera")
    private let onCapture: (Data) -> Void
    private let onCancel: () -> Void
    private let onFailure: () -> Void
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var cameraDevice: AVCaptureDevice?
    private var zoomFactorAtGestureStart: CGFloat = 1
    private var isConfigured = false

    init(
        onCapture: @escaping (Data) -> Void,
        onCancel: @escaping () -> Void,
        onFailure: @escaping () -> Void
    ) {
        self.onCapture = onCapture
        self.onCancel = onCancel
        self.onFailure = onFailure
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureControls()
        configureZoomGesture()
        configureCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func configureCamera() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            defer { self.session.commitConfiguration() }

            guard
                let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                let input = try? AVCaptureDeviceInput(device: camera),
                self.session.canAddInput(input),
                self.session.canAddOutput(self.photoOutput)
            else {
                DispatchQueue.main.async { self.onFailure() }
                return
            }

            self.session.addInput(input)
            self.session.addOutput(self.photoOutput)
            self.cameraDevice = camera
            self.isConfigured = true

            DispatchQueue.main.async {
                let layer = AVCaptureVideoPreviewLayer(session: self.session)
                layer.videoGravity = .resizeAspectFill
                layer.frame = self.view.bounds
                self.view.layer.insertSublayer(layer, at: 0)
                self.previewLayer = layer
                self.sessionQueue.async {
                    guard !self.session.isRunning else { return }
                    self.session.startRunning()
                }
            }
        }
    }

    private func configureControls() {
        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        closeButton.layer.cornerRadius = 22
        closeButton.accessibilityLabel = "Abbrechen"
        closeButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)

        let shutterButton = UIButton(type: .custom)
        shutterButton.backgroundColor = .white
        shutterButton.layer.borderColor = UIColor.white.withAlphaComponent(0.55).cgColor
        shutterButton.layer.borderWidth = 6
        shutterButton.layer.cornerRadius = 38
        shutterButton.accessibilityLabel = "Foto aufnehmen und speichern"
        shutterButton.accessibilityIdentifier = "quickCapture.shutter"
        shutterButton.addTarget(self, action: #selector(capturePhoto), for: .touchUpInside)

        [closeButton, shutterButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            shutterButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shutterButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            shutterButton.widthAnchor.constraint(equalToConstant: 76),
            shutterButton.heightAnchor.constraint(equalToConstant: 76),
        ])
    }

    private func configureZoomGesture() {
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        view.addGestureRecognizer(pinchGesture)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let cameraDevice else { return }

        switch gesture.state {
        case .began:
            zoomFactorAtGestureStart = cameraDevice.videoZoomFactor
        case .changed:
            let requestedFactor = zoomFactorAtGestureStart * gesture.scale
            let maximumFactor = min(cameraDevice.activeFormat.videoMaxZoomFactor, 10)
            let zoomFactor = max(1, min(requestedFactor, maximumFactor))
            do {
                try cameraDevice.lockForConfiguration()
                cameraDevice.videoZoomFactor = zoomFactor
                cameraDevice.unlockForConfiguration()
            } catch {
                AppLogger.capture.error("Quick camera zoom could not be updated")
            }
        default:
            break
        }
    }

    @objc private func cancel() {
        onCancel()
    }

    @objc private func capturePhoto(_ sender: UIButton) {
        sender.isEnabled = false
        let settings = AVCapturePhotoSettings()
        if photoOutput.supportedFlashModes.contains(.auto) {
            settings.flashMode = .auto
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            DispatchQueue.main.async { self.onFailure() }
            return
        }
        DispatchQueue.main.async { self.onCapture(data) }
    }
}

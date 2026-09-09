@preconcurrency import AVFoundation
import SwiftUI
import UIKit

struct DirectCameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    let onCancel: () -> Void
    let onFailure: () -> Void

    func makeUIViewController(context: Context) -> DirectCameraCaptureViewController {
        DirectCameraCaptureViewController(
            onCapture: onCapture,
            onCancel: onCancel,
            onFailure: onFailure
        )
    }

    func updateUIViewController(
        _ uiViewController: DirectCameraCaptureViewController,
        context: Context
    ) {}
}

final class DirectCameraCaptureViewController: UIViewController, AVCapturePhotoCaptureDelegate {
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "de.clemensgerbaulet.quant.direct-camera")
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let captureButton = UIButton(type: .custom)
    private let onCapture: (Data) -> Void
    private let onCancel: () -> Void
    private let onFailure: () -> Void
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
        view.accessibilityIdentifier = "meal.directCamera"
        configurePreview()
        configureControls()
        configureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
        updateVideoOrientation()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        let session = session
        sessionQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func configurePreview() {
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
    }

    private func configureControls() {
        captureButton.translatesAutoresizingMaskIntoConstraints = false
        captureButton.backgroundColor = .white
        captureButton.layer.cornerRadius = 37
        captureButton.layer.borderColor = UIColor.white.withAlphaComponent(0.45).cgColor
        captureButton.layer.borderWidth = 6
        captureButton.isEnabled = false
        captureButton.accessibilityLabel = "Foto aufnehmen"
        captureButton.accessibilityIdentifier = "meal.directCamera.shutter"
        captureButton.addTarget(self, action: #selector(capturePhoto), for: .touchUpInside)

        var cancelConfiguration = UIButton.Configuration.plain()
        cancelConfiguration.title = "Abbrechen"
        cancelConfiguration.baseForegroundColor = .white
        cancelConfiguration.background.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        cancelConfiguration.background.cornerRadius = 12
        let cancelButton = UIButton(configuration: cancelConfiguration)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.accessibilityIdentifier = "meal.directCamera.cancel"
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)

        view.addSubview(captureButton)
        view.addSubview(cancelButton)
        NSLayoutConstraint.activate([
            captureButton.widthAnchor.constraint(equalToConstant: 74),
            captureButton.heightAnchor.constraint(equalTo: captureButton.widthAnchor),
            captureButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captureButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            cancelButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            cancelButton.centerYAnchor.constraint(equalTo: captureButton.centerYAnchor),
        ])
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard
            let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: camera),
            session.canAddInput(input),
            session.canAddOutput(photoOutput)
        else {
            session.commitConfiguration()
            DispatchQueue.main.async { [weak self] in
                self?.onFailure()
            }
            return
        }

        session.addInput(input)
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality
        isConfigured = true
        session.commitConfiguration()

        let session = session
        sessionQueue.async { [weak self] in
            session.startRunning()
            DispatchQueue.main.async {
                self?.captureButton.isEnabled = session.isRunning
            }
        }
    }

    @objc private func capturePhoto() {
        guard isConfigured, session.isRunning, captureButton.isEnabled else { return }
        captureButton.isEnabled = false
        updateVideoOrientation()

        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    @objc private func cancel() {
        onCancel()
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            captureButton.isEnabled = true
            onFailure()
            return
        }
        onCapture(data)
    }

    private func updateVideoOrientation() {
        guard let orientation = view.window?.windowScene?.effectiveGeometry.interfaceOrientation else { return }
        let rotationAngle: CGFloat
        switch orientation {
        case .portrait:
            rotationAngle = 90
        case .portraitUpsideDown:
            rotationAngle = 270
        case .landscapeLeft:
            rotationAngle = 0
        case .landscapeRight:
            rotationAngle = 180
        default:
            return
        }
        if let previewConnection = previewLayer.connection,
           previewConnection.isVideoRotationAngleSupported(rotationAngle) {
            previewConnection.videoRotationAngle = rotationAngle
        }
        if let photoConnection = photoOutput.connection(with: .video),
           photoConnection.isVideoRotationAngleSupported(rotationAngle) {
            photoConnection.videoRotationAngle = rotationAngle
        }
    }
}

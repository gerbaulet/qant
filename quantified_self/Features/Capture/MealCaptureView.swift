import AVFoundation
import OSLog
import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct MealCaptureView: View {
    private static let maximumImageCount = 6

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private let imageStorage: any ImageStorageProviding
    private let analysisProvider: any NutritionAnalysisProviding
    private let opensCameraOnAppear: Bool
    private let cameraCaptureFlow: CameraCaptureFlow
    private let initialTimestamp: Date

    @State private var timestamp: Date
    @State private var comment = ""
    @State private var attachedImages: [PendingMealImage] = []
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var showsCamera = false
    @State private var isImportingImages = false
    @State private var isSaving = false
    @State private var alert: CaptureAlert?
    @State private var showsDetails = false
    @State private var showsDiscardConfirmation = false
    @State private var hasAttemptedAutomaticCamera = false
    @FocusState private var commentIsFocused: Bool

    init(
        now: Date = .now,
        imageStorage: any ImageStorageProviding = FileImageStorage(),
        analysisProvider: any NutritionAnalysisProviding = OpenRouterNutritionAnalysisService(),
        opensCameraOnAppear: Bool = false
    ) {
        self.imageStorage = imageStorage
        self.analysisProvider = analysisProvider
        self.opensCameraOnAppear = opensCameraOnAppear
        self.cameraCaptureFlow = .forCapture(openedFromShortcut: opensCameraOnAppear)
        self.initialTimestamp = now
        _timestamp = State(initialValue: now)
    }

    var body: some View {
        NavigationStack {
            captureContent
                .accessibilityIdentifier("meal.captureForm")
                .accessibilityValue(opensCameraOnAppear ? "Kamera" : "Standard")
                .background(Color(.systemGroupedBackground))
                .navigationTitle(opensCameraOnAppear ? "Schnellaufnahme" : "Neue Mahlzeit")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Abbrechen", action: requestDismiss)
                            .disabled(isSaving)
                    }

                    if !opensCameraOnAppear {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Speichern") { save() }
                                .fontWeight(.semibold)
                                .disabled(isSaving || isImportingImages)
                                .accessibilityIdentifier("meal.save")
                        }
                    }

                    if !opensCameraOnAppear {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Fertig") {
                                commentIsFocused = false
                            }
                        }
                    }
                }
                .onChange(of: photoPickerItems) { _, items in
                    guard !items.isEmpty else { return }
                    Task { await importPhotos(items) }
                }
                .task {
                    guard opensCameraOnAppear, !hasAttemptedAutomaticCamera else { return }
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    hasAttemptedAutomaticCamera = true
                    requestCamera()
                }
                .fullScreenCover(isPresented: $showsCamera) {
                    if cameraCaptureFlow == .useImmediately {
                        DirectCameraCaptureView { imageData in
                            Task { await saveQuickCapture(imageData) }
                        } onCancel: {
                            showsCamera = false
                            dismiss()
                        } onFailure: {
                            showsCamera = false
                            alert = .cameraCaptureFailed
                        }
                        .ignoresSafeArea()
                    } else {
                        CameraPicker { imageData in
                            showsCamera = false
                            Task {
                                isImportingImages = true
                                defer { isImportingImages = false }
                                await addImageData(imageData)
                            }
                        } onCancel: {
                            showsCamera = false
                        }
                        .ignoresSafeArea()
                    }
                }
                .alert(item: $alert) { alert in
                    if alert.offersSettings {
                        Alert(
                            title: Text(alert.title),
                            message: Text(alert.message),
                            primaryButton: .default(Text("Einstellungen öffnen"), action: openSettings),
                            secondaryButton: .cancel(Text("Abbrechen"))
                        )
                    } else {
                        Alert(
                            title: Text(alert.title),
                            message: Text(alert.message),
                            dismissButton: .default(Text("OK"))
                        )
                    }
                }
                .alert("Änderungen verwerfen?", isPresented: $showsDiscardConfirmation) {
                    Button("Weiter bearbeiten", role: .cancel) {}
                    Button("Verwerfen", role: .destructive) { dismiss() }
                } message: {
                    Text("Fotos, Kommentar und geänderter Zeitpunkt werden nicht gespeichert.")
                }
        }
        .interactiveDismissDisabled(isSaving || hasUnsavedChanges)
        .overlay(alignment: .top) {
            if hasUnsavedChanges, !isSaving {
                SheetDismissAttemptGestureView(onAttempt: handleInteractiveDismissAttempt)
                    .frame(width: 144, height: 120)
                    .accessibilityIdentifier("meal.dismissHandle")
            }
        }
    }

    @ViewBuilder
    private var captureContent: some View {
        if opensCameraOnAppear {
            VStack {
                Spacer()
                ProgressView("Kamera wird geöffnet …")
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: QuantLayout.sectionSpacing) {
                    photosCard
                    commentCard
                    detailsCard
                }
                .padding(.horizontal, QuantLayout.pageInset)
                .padding(.vertical, QuantLayout.sectionSpacing)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var commentCard: some View {
        QuantCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Kommentar (optional)")
                    .font(.headline)
                TextField(
                    "z. B. große Portion, ungefähr 350 g",
                    text: $comment,
                    axis: .vertical
                )
                .lineLimit(4...8)
                .textFieldStyle(.roundedBorder)
                .focused($commentIsFocused)
                .accessibilityIdentifier("meal.comment")
                Text("Gewicht, Portionsgröße oder besondere Zutaten helfen bei der Analyse.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detailsCard: some View {
        QuantCard {
            DisclosureGroup("Details", isExpanded: $showsDetails) {
                DatePicker(
                    "Zeitpunkt",
                    selection: $timestamp,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .padding(.top, 12)
                .accessibilityIdentifier("meal.timestamp")
            }
            .accessibilityIdentifier("meal.detailsDisclosure")
        }
    }

    private var photosCard: some View {
        QuantCard(style: .hero) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Fotos")
                    .font(.headline)

                if attachedImages.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 36, weight: .medium))
                            .foregroundStyle(.tint)
                        Text("Fotografiere die Mahlzeit")
                            .font(.title3.weight(.semibold))
                        Text("Zusätzliche Fotos von Verpackung oder Nährwerttabelle verbessern die Schätzung.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 12) {
                            ForEach(attachedImages) { image in
                                PendingMealImageThumbnail(image: image) {
                                    attachedImages.removeAll { $0.id == image.id }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.hidden)
                }

                Button(action: requestCamera) {
                    Label("Kamera öffnen", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canAddImages || isImportingImages || isSaving)
                .accessibilityIdentifier("meal.camera")

                PhotosPicker(
                    selection: $photoPickerItems,
                    maxSelectionCount: remainingImageCapacity,
                    matching: .images
                ) {
                    Label("Aus Mediathek wählen", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!canAddImages || isImportingImages || isSaving)
                .accessibilityIdentifier("meal.photoLibrary")

                if isImportingImages {
                    HStack {
                        ProgressView()
                        Text("Fotos werden vorbereitet …")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Bis zu \(Self.maximumImageCount) Fotos, zum Beispiel Übersicht, Verpackung oder Nährwerttabelle.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var canAddImages: Bool {
        attachedImages.count < Self.maximumImageCount
    }

    private var remainingImageCapacity: Int {
        max(1, Self.maximumImageCount - attachedImages.count)
    }

    private var hasUnsavedChanges: Bool {
        !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !attachedImages.isEmpty ||
            abs(timestamp.timeIntervalSince(initialTimestamp)) > 0.5
    }

    private func requestDismiss() {
        if hasUnsavedChanges {
            showsDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private func handleInteractiveDismissAttempt() {
        guard hasUnsavedChanges, !isSaving else { return }
        showsDiscardConfirmation = true
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        isImportingImages = true
        defer {
            isImportingImages = false
            photoPickerItems = []
        }

        for item in items.prefix(remainingImageCapacity) {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw ImageStorageError.invalidImage
                }
                await addImageData(data)
            } catch {
                alert = .imageImportFailed
                return
            }
        }
    }

    private func addImageData(_ data: Data) async {
        guard canAddImages else { return }
        do {
            attachedImages.append(try await PendingMealImage.prepare(data: data))
        } catch {
            alert = .imageImportFailed
        }
    }

    private func requestCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            alert = .cameraUnavailable
            return
        }

        Task {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                showsCamera = true
            case .notDetermined:
                showsCamera = await AVCaptureDevice.requestAccess(for: .video)
                if !showsCamera {
                    alert = .cameraDenied
                }
            case .denied, .restricted:
                alert = .cameraDenied
            @unknown default:
                alert = .cameraDenied
            }
        }
    }

    private func save(shouldAnalyze: Bool = true) {
        guard !isSaving else { return }
        isSaving = true

        Task {
            var storedImages: [StoredMealImage] = []
            do {
                for image in attachedImages {
                    storedImages.append(try await imageStorage.storeImageData(image.data, id: image.id))
                }

                let repository = SwiftDataMealRepository(context: modelContext)
                let meal = try repository.createMeal(from: MealDraft(
                    timestamp: timestamp,
                    comment: comment,
                    category: .unspecified,
                    images: storedImages,
                    analysisState: shouldAnalyze ? .pending : .awaitingDescription
                ))
                dismiss()
                if shouldAnalyze {
                    await MealAnalysisQueue.shared.analyze(
                        meal,
                        in: modelContext,
                        provider: analysisProvider,
                        imageStorage: imageStorage
                    )
                }
            } catch {
                for image in storedImages {
                    await imageStorage.deleteImage(image)
                }
                AppLogger.persistence.error("Capture workflow could not save meal")
                alert = .saveFailed
                isSaving = false
            }
        }
    }

    private func saveQuickCapture(_ imageData: Data) async {
        isImportingImages = true
        defer { isImportingImages = false }
        do {
            attachedImages = [try await PendingMealImage.prepare(data: imageData)]
        } catch {
            showsCamera = false
            alert = .imageImportFailed
            return
        }
        timestamp = .now
        save(shouldAnalyze: false)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct SheetDismissAttemptGestureView: UIViewRepresentable {
    let onAttempt: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onAttempt: onAttempt)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let recognizer = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        recognizer.delegate = context.coordinator
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onAttempt = onAttempt
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onAttempt: () -> Void
        private var hasAttempted = false

        init(onAttempt: @escaping () -> Void) {
            self.onAttempt = onAttempt
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                hasAttempted = false
            case .changed:
                let translation = recognizer.translation(in: recognizer.view)
                guard !hasAttempted,
                      translation.y > 100,
                      abs(translation.y) > abs(translation.x)
                else { return }
                hasAttempted = true
                onAttempt()
            case .ended, .cancelled, .failed:
                hasAttempted = false
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

#Preview {
    MealCaptureView()
        .modelContainer(for: NutritionSchemaV2.models, inMemory: true)
}

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

    private let classificationSchedule: MealClassificationSchedule
    private let calendar: Calendar
    private let imageStorage: any ImageStorageProviding
    private let analysisProvider: any NutritionAnalysisProviding
    private let opensCameraOnAppear: Bool

    @State private var timestamp: Date
    @State private var comment = ""
    @State private var category: MealCategory
    @State private var usesAutomaticCategory = true
    @State private var attachedImages: [PendingMealImage] = []
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var showsCamera = false
    @State private var isImportingImages = false
    @State private var isSaving = false
    @State private var alert: CaptureAlert?
    @State private var showsTimestamp = false
    @State private var showsMealCategory = false
    @State private var hasAttemptedAutomaticCamera = false
    @FocusState private var commentIsFocused: Bool

    init(
        now: Date = .now,
        classificationSchedule: MealClassificationSchedule = .default,
        calendar: Calendar = .autoupdatingCurrent,
        imageStorage: any ImageStorageProviding = FileImageStorage(),
        analysisProvider: any NutritionAnalysisProviding = OpenRouterNutritionAnalysisService(),
        opensCameraOnAppear: Bool = false
    ) {
        self.classificationSchedule = classificationSchedule
        self.calendar = calendar
        self.imageStorage = imageStorage
        self.analysisProvider = analysisProvider
        self.opensCameraOnAppear = opensCameraOnAppear
        _timestamp = State(initialValue: now)
        _category = State(initialValue: classificationSchedule.category(
            for: now,
            calendar: calendar
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                if opensCameraOnAppear {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Kamera wird geöffnet …")
                            Spacer()
                        }
                    }
                } else {
                    photosSection

                    Section {
                        TextField(
                            "z. B. große Portion, ungefähr 350 g",
                            text: $comment,
                            axis: .vertical
                        )
                        .lineLimit(4...8)
                        .focused($commentIsFocused)
                        .accessibilityIdentifier("meal.comment")
                    } header: {
                        Text("Kommentar (optional)")
                    } footer: {
                        Text("Gewicht, Portionsgröße oder besondere Zutaten helfen später bei der Analyse.")
                    }

                    timestampSection
                    mealCategorySection
                }
            }
            .accessibilityIdentifier("meal.captureForm")
            .accessibilityValue(opensCameraOnAppear ? "Kamera" : "Standard")
            .navigationTitle(opensCameraOnAppear ? "Schnellaufnahme" : "Neue Mahlzeit")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }

                if !opensCameraOnAppear {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Speichern", action: save)
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
            .onChange(of: timestamp) {
                if usesAutomaticCategory {
                    updateAutomaticCategory()
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
                CameraPicker { imageData in
                    if opensCameraOnAppear {
                        saveQuickCapture(imageData)
                    } else {
                        showsCamera = false
                        addImageData(imageData)
                    }
                } onCancel: {
                    showsCamera = false
                    if opensCameraOnAppear {
                        dismiss()
                    }
                }
                .ignoresSafeArea()
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
        }
    }

    private var timestampSection: some View {
        Section {
            DisclosureGroup("Zeitpunkt", isExpanded: $showsTimestamp) {
                DatePicker(
                    "Mahlzeit",
                    selection: $timestamp,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .accessibilityIdentifier("meal.timestamp")
            }
            .accessibilityIdentifier("meal.timestampDisclosure")
        }
    }

    private var mealCategorySection: some View {
        Section {
            DisclosureGroup("Art der Mahlzeit", isExpanded: $showsMealCategory) {
                Picker("Kategorie", selection: categoryBinding) {
                    ForEach(MealCategory.allCases, id: \.self) { category in
                        Text(category.captureTitle).tag(category)
                    }
                }
                .accessibilityIdentifier("meal.category")

                if !usesAutomaticCategory {
                    Button("Wieder automatisch bestimmen") {
                        usesAutomaticCategory = true
                        updateAutomaticCategory()
                    }
                } else {
                    Label("Automatisch nach Uhrzeit gewählt", systemImage: "clock.badge.checkmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("meal.categoryDisclosure")
        }
    }

    private var photosSection: some View {
        Section {
            if attachedImages.isEmpty {
                Label("Noch keine Fotos ausgewählt", systemImage: "photo.on.rectangle.angled")
                    .foregroundStyle(.secondary)
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

            HStack(spacing: 12) {
                PhotosPicker(
                    selection: $photoPickerItems,
                    maxSelectionCount: remainingImageCapacity,
                    matching: .images
                ) {
                    Label("Mediathek", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!canAddImages || isImportingImages || isSaving)
                .accessibilityIdentifier("meal.photoLibrary")

                Button(action: requestCamera) {
                    Label("Kamera", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!canAddImages || isImportingImages || isSaving)
                .accessibilityIdentifier("meal.camera")
            }

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
        } header: {
            Text("Fotos")
        }
    }

    private var canAddImages: Bool {
        attachedImages.count < Self.maximumImageCount
    }

    private var remainingImageCapacity: Int {
        max(1, Self.maximumImageCount - attachedImages.count)
    }

    private var categoryBinding: Binding<MealCategory> {
        Binding(
            get: { category },
            set: {
                category = $0
                usesAutomaticCategory = false
            }
        )
    }

    private func updateAutomaticCategory() {
        category = classificationSchedule.category(for: timestamp, calendar: calendar)
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
                addImageData(data)
            } catch {
                alert = .imageImportFailed
                return
            }
        }
    }

    private func addImageData(_ data: Data) {
        guard canAddImages, UIImage(data: data) != nil else {
            alert = .imageImportFailed
            return
        }
        attachedImages.append(PendingMealImage(data: data))
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

    private func save() {
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
                    category: category,
                    images: storedImages
                ))
                let coordinator = MealAnalysisCoordinator(
                    context: modelContext,
                    provider: analysisProvider,
                    imageStorage: imageStorage
                )
                dismiss()
                await coordinator.analyze(meal)
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

    private func saveQuickCapture(_ imageData: Data) {
        guard UIImage(data: imageData) != nil else {
            showsCamera = false
            alert = .imageImportFailed
            return
        }
        attachedImages = [PendingMealImage(data: imageData)]
        save()
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private extension MealCategory {
    var captureTitle: LocalizedStringKey {
        switch self {
        case .breakfast: "Frühstück"
        case .lunch: "Mittagessen"
        case .dinner: "Abendessen"
        case .snack: "Snack"
        }
    }
}

#Preview {
    MealCaptureView()
        .modelContainer(for: NutritionSchemaV1.models, inMemory: true)
}

import OSLog
import SwiftData
import SwiftUI

struct MealsHistoryContainer: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Meal.timestamp, order: .reverse) private var meals: [Meal]
    @State private var grouping = MealHistoryGrouping.day
    @State private var searchText = ""
    @State private var selectedMeal: Meal?
    @State private var mealPendingDeletion: Meal?
    @State private var duplicateConfirmationMealID: UUID?
    @State private var alertMessage: String?
    private let imageStorage: any ImageStorageProviding = FileImageStorage()

    var body: some View {
        MealsHistoryView(
            sections: MealHistoryBuilder.makeSections(
                meals: meals,
                grouping: grouping,
                calendar: .autoupdatingCurrent,
                searchQuery: searchText
            ),
            grouping: $grouping,
            searchText: $searchText,
            onOpenMeal: openMeal,
            onRetryMeal: retryAnalysis,
            onDuplicateMeal: duplicateMealFromHistory,
            onDeleteMeal: requestDeletion
        )
        .sheet(item: $selectedMeal) { meal in
            NavigationStack {
                MealReviewView(
                    meal: meal,
                    showsDuplicateConfirmation: duplicateConfirmationMealID == meal.id,
                    onDelete: deleteMeal,
                    onDuplicate: duplicateMeal
                )
            }
        }
        .confirmationDialog(
            "Mahlzeit löschen?",
            isPresented: deletionConfirmationBinding,
            presenting: mealPendingDeletion
        ) { meal in
            Button("Mahlzeit löschen", role: .destructive) {
                deleteMeal(meal)
            }
            Button("Abbrechen", role: .cancel) {
                mealPendingDeletion = nil
            }
        } message: { _ in
            Text("Die Mahlzeit, ihre Analyse und ihre Fotos werden dauerhaft gelöscht.")
        }
        .alert("Aktion nicht möglich", isPresented: alertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "Unbekannter Fehler")
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickCaptureRequested)) { _ in
            selectedMeal = nil
            mealPendingDeletion = nil
        }
    }

    private func openMeal(_ id: UUID) {
        selectedMeal = meals.first { $0.id == id }
    }

    private func retryAnalysis(_ id: UUID) {
        guard let meal = meals.first(where: { $0.id == id }) else { return }
        Task { await MealAnalysisQueue.shared.analyze(meal, in: modelContext) }
    }

    private func requestDeletion(_ id: UUID) {
        mealPendingDeletion = meals.first { $0.id == id }
    }

    private func duplicateMealFromHistory(_ id: UUID) {
        guard let meal = meals.first(where: { $0.id == id }) else { return }
        Task {
            do {
                try await duplicateMeal(meal)
            } catch {
                alertMessage = "Die Mahlzeit konnte nicht dupliziert werden."
            }
        }
    }

    @MainActor
    private func duplicateMeal(_ meal: Meal) async throws {
        let duplicate = try await MealDuplicationCoordinator(context: modelContext).duplicate(meal)
        duplicateConfirmationMealID = duplicate.id
        selectedMeal = duplicate
        Task {
            try? await Task.sleep(for: .seconds(3))
            if duplicateConfirmationMealID == duplicate.id {
                duplicateConfirmationMealID = nil
            }
        }
    }

    private var deletionConfirmationBinding: Binding<Bool> {
        Binding(
            get: { mealPendingDeletion != nil },
            set: { if !$0 { mealPendingDeletion = nil } }
        )
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )
    }

    private func deleteMeal(_ meal: Meal) {
        MealAnalysisQueue.shared.cancel(for: meal.id, in: modelContext)
        do {
            let images = try SwiftDataMealRepository(context: modelContext).deleteMeal(meal)
            selectedMeal = nil
            mealPendingDeletion = nil
            Task {
                for image in images {
                    await imageStorage.deleteImage(image)
                }
            }
        } catch {
            AppLogger.persistence.error("Meal deletion failed")
        }
    }
}

struct MealsHistoryView: View {
    let sections: [MealHistorySection]
    @Binding var grouping: MealHistoryGrouping
    @Binding var searchText: String
    let onOpenMeal: (UUID) -> Void
    let onRetryMeal: (UUID) -> Void
    let onDuplicateMeal: (UUID) -> Void
    let onDeleteMeal: (UUID) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Gruppierung", selection: $grouping) {
                    Text("Tag").tag(MealHistoryGrouping.day)
                    Text("Woche").tag(MealHistoryGrouping.week)
                    Text("Monat").tag(MealHistoryGrouping.month)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
                .accessibilityIdentifier("meals.grouping")

                Group {
                    if sections.isEmpty {
                        ContentUnavailableView(
                            isSearching ? "Keine Mahlzeiten gefunden" : "Noch keine Mahlzeiten",
                            systemImage: isSearching ? "magnifyingglass" : "fork.knife",
                            description: Text(
                                isSearching
                                    ? "Versuche einen anderen Suchbegriff."
                                    : "Erfasste Mahlzeiten erscheinen hier in deinem Verlauf."
                            )
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List {
                            ForEach(sections) { section in
                                Section {
                                    ForEach(section.entries) { entry in
                                        mealRow(entry)
                                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                                Button(role: .destructive) {
                                                    onDeleteMeal(entry.id)
                                                } label: {
                                                    Label("Löschen", systemImage: "trash")
                                                }
                                                .accessibilityIdentifier("meal.delete.\(entry.id)")
                                                if entry.analysisState == .confirmed {
                                                    Button {
                                                        onDuplicateMeal(entry.id)
                                                    } label: {
                                                        Label("Duplizieren", systemImage: "plus.square.on.square")
                                                    }
                                                    .tint(.blue)
                                                    .accessibilityIdentifier("meal.duplicate.\(entry.id)")
                                                }
                                            }
                                    }
                                } header: {
                                    sectionHeader(section)
                                }
                            }
                        }
                        .listStyle(.insetGrouped)
                    }
                }
            }
            .navigationTitle("Mahlzeiten")
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Mahlzeiten durchsuchen"
            )
        }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func mealRow(_ entry: MealHistoryEntry) -> some View {
        HStack(spacing: 12) {
            Button { onOpenMeal(entry.id) } label: {
                HStack(spacing: 12) {
                    StoredMealThumbnailView(storageKey: entry.thumbnailStorageKey)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.name?.isEmpty == false ? entry.name! : "Mahlzeit")
                            .font(.headline)
                            .lineLimit(1)
                        HStack(spacing: 7) {
                            Text(entry.timestamp, format: .dateTime.hour().minute())
                            if entry.analysisState != .confirmed {
                                Label(entry.analysisState.historyTitle, systemImage: entry.analysisState.historySystemImage)
                                    .foregroundStyle(entry.analysisState.historyColor)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let energy = entry.energyKilocalories {
                        Text("\(entry.isProvisional ? "~" : "")\(wholeNumber(energy)) kcal")
                            .font(.subheadline.bold().monospacedDigit())
                    }
                }
            }
            .buttonStyle(.plain)

            if entry.analysisState == .failed {
                Button { onRetryMeal(entry.id) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Analyse erneut versuchen")
            }
        }
    }

    private func sectionTitle(_ section: MealHistorySection) -> String {
        switch grouping {
        case .day:
            section.interval.start.formatted(.dateTime.weekday(.wide).day().month(.wide))
        case .week:
            "Woche ab \(section.interval.start.formatted(.dateTime.day().month()))"
        case .month:
            section.interval.start.formatted(.dateTime.month(.wide).year())
        }
    }

    private func sectionHeader(_ section: MealHistorySection) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(sectionTitle(section))
            if !isSearching {
                Spacer(minLength: 12)
                if let total = section.totalEnergyKilocalories {
                    Text("\(section.containsProvisionalEnergy ? "~" : "")\(wholeNumber(total)) kcal")
                        .monospacedDigit()
                } else {
                    Text("— kcal")
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func wholeNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }
}

private extension AnalysisState {
    var historyTitle: LocalizedStringKey {
        switch self {
        case .awaitingDescription: "Beschreibung fehlt"
        case .pending: "Ausstehend"
        case .analyzing: "Analyse"
        case .needsClarification: "Rückfrage"
        case .awaitingConfirmation: "Zu bestätigen"
        case .confirmed: "Bestätigt"
        case .failed: "Fehlgeschlagen"
        }
    }

    var historySystemImage: String {
        switch self {
        case .awaitingDescription: "text.bubble"
        case .pending: "clock"
        case .analyzing: "sparkles"
        case .needsClarification: "questionmark.circle"
        case .awaitingConfirmation: "checkmark.circle"
        case .confirmed: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var historyColor: Color {
        switch self {
        case .awaitingDescription: .orange
        case .pending, .analyzing: .secondary
        case .needsClarification, .awaitingConfirmation: .orange
        case .confirmed: .green
        case .failed: .red
        }
    }
}

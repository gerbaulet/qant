import OSLog
import SwiftData
import SwiftUI

struct MealsHistoryContainer: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Meal.timestamp, order: .reverse) private var meals: [Meal]
    @State private var grouping = MealHistoryGrouping.day
    @State private var selectedMeal: Meal?
    @State private var mealPendingDeletion: Meal?
    private let imageStorage: any ImageStorageProviding = FileImageStorage()

    var body: some View {
        MealsHistoryView(
            sections: MealHistoryBuilder.makeSections(
                meals: meals,
                grouping: grouping,
                calendar: .autoupdatingCurrent
            ),
            grouping: $grouping,
            onOpenMeal: openMeal,
            onRetryMeal: retryAnalysis,
            onDeleteMeal: requestDeletion
        )
        .sheet(item: $selectedMeal) { meal in
            NavigationStack {
                MealReviewView(meal: meal) {
                    deleteMeal(meal)
                }
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
        Task { await MealAnalysisCoordinator(context: modelContext).analyze(meal) }
    }

    private func requestDeletion(_ id: UUID) {
        mealPendingDeletion = meals.first { $0.id == id }
    }

    private var deletionConfirmationBinding: Binding<Bool> {
        Binding(
            get: { mealPendingDeletion != nil },
            set: { if !$0 { mealPendingDeletion = nil } }
        )
    }

    private func deleteMeal(_ meal: Meal) {
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
    let onOpenMeal: (UUID) -> Void
    let onRetryMeal: (UUID) -> Void
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
                            "Noch keine Mahlzeiten",
                            systemImage: "fork.knife",
                            description: Text("Erfasste Mahlzeiten erscheinen hier in deinem Verlauf.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List {
                            ForEach(sections) { section in
                                Section(sectionTitle(section)) {
                                    ForEach(section.entries) { entry in
                                        mealRow(entry)
                                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                                Button(role: .destructive) {
                                                    onDeleteMeal(entry.id)
                                                } label: {
                                                    Label("Löschen", systemImage: "trash")
                                                }
                                                .accessibilityIdentifier("meal.delete.\(entry.id)")
                                            }
                                    }
                                }
                            }
                        }
                        .listStyle(.insetGrouped)
                    }
                }
            }
            .navigationTitle("Mahlzeiten")
        }
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
                            Text(entry.category.historyTitle)
                            Label(entry.analysisState.historyTitle, systemImage: entry.analysisState.historySystemImage)
                                .foregroundStyle(entry.analysisState.historyColor)
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

    private func wholeNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }
}

private extension MealCategory {
    var historyTitle: LocalizedStringKey {
        switch self {
        case .breakfast: "Frühstück"
        case .lunch: "Mittagessen"
        case .dinner: "Abendessen"
        case .snack: "Snack"
        }
    }
}

private extension AnalysisState {
    var historyTitle: LocalizedStringKey {
        switch self {
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
        case .pending, .analyzing: .secondary
        case .needsClarification, .awaitingConfirmation: .orange
        case .confirmed: .green
        case .failed: .red
        }
    }
}

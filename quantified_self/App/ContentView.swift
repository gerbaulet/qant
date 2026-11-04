import OSLog
import SwiftData
import SwiftUI

struct ContentView: View {
    private enum AppSection: Hashable {
        case today
        case meals
        case trends
        case settings
    }

    private enum MealCaptureMode: Identifiable, Hashable {
        case standard
        case camera

        var id: Self { self }
    }

    @State private var selectedSection: AppSection = .today
    @State private var mealCaptureMode: MealCaptureMode?
    @State private var activeQuickCaptureRequestID: UUID?
    @State private var activeAnalysisMeal: Meal?
    @State private var analysisProgressStore = MealAnalysisProgressStore.shared
    @AppStorage("weeklySummaryReminderEnabled") private var weeklyReminderEnabled = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Meal.timestamp, order: .reverse) private var meals: [Meal]
    private let quickCaptureRequests = QuickCaptureRequestStore()
    private let weeklyReminderScheduler = WeeklySummaryNotificationScheduler()

    var body: some View {
        TabView(selection: $selectedSection) {
            Tab("Heute", systemImage: "sun.max.fill", value: .today) {
                TodayDashboardContainer(isActive: selectedSection == .today) {
                    mealCaptureMode = .standard
                }
            }

            Tab("Mahlzeiten", systemImage: "fork.knife", value: .meals) {
                MealsHistoryContainer()
            }

            Tab("Trends", systemImage: "chart.xyaxis.line", value: .trends) {
                NutritionTrendsContainer(isActive: selectedSection == .trends)
            }

            Tab("Einstellungen", systemImage: "gearshape", value: .settings) {
                OpenRouterSettingsView(isActive: selectedSection == .settings)
            }
        }
        .sheet(item: $mealCaptureMode) { mode in
            MealCaptureView(opensCameraOnAppear: mode == .camera)
        }
        .sheet(item: $activeAnalysisMeal) { meal in
            NavigationStack {
                MealReviewView(
                    meal: meal,
                    onDelete: deleteMeal,
                    onDuplicate: duplicateMeal
                )
            }
        }
        .overlay(alignment: .topTrailing) {
            if !analysisProgressStore.analyses.isEmpty {
                Button(action: openMostRelevantAnalysis) {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(analysisProgressStore.analyses.count, format: .number)
                            .font(.caption.bold().monospacedDigit())
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: .capsule)
                    .shadow(radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Laufende OpenRouter-Analysen: \(analysisProgressStore.analyses.count)")
                .accessibilityIdentifier("analysis.activity")
                .padding(.top, 6)
                .padding(.trailing, 12)
            }
        }
        .onAppear(perform: presentRequestedQuickCapture)
        .task {
#if DEBUG
            if !ProcessInfo.processInfo.arguments.contains("--ui-testing-review-progress") {
                try? MealAnalysisQueue.shared.resumePendingAnalyses(in: modelContext)
            }
#else
            try? MealAnalysisQueue.shared.resumePendingAnalyses(in: modelContext)
#endif
            if weeklyReminderEnabled {
                _ = await weeklyReminderScheduler.enable()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickCaptureRequested)) { _ in
            presentRequestedQuickCapture()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                presentRequestedQuickCapture()
            }
        }
        .onOpenURL { url in
            guard url == QuantWidgetConfiguration.todayURL else { return }
            selectedSection = .today
        }
    }

    private func presentRequestedQuickCapture() {
        guard quickCaptureRequests.consumeCaptureRequest() else { return }
        let requestID = UUID()
        activeQuickCaptureRequestID = requestID
        selectedSection = .today
        mealCaptureMode = nil
        Task {
            // Let any nested review sheet finish dismissing before presenting
            // the camera sheet. SwiftUI otherwise drops the new presentation.
            try? await Task.sleep(for: .milliseconds(800))
            guard activeQuickCaptureRequestID == requestID else { return }
            mealCaptureMode = .camera
        }
    }

    private func openMostRelevantAnalysis() {
        activeAnalysisMeal = meals
            .filter { analysisProgressStore.analyses[$0.id] != nil }
            .sorted { lhs, rhs in
                let lhsNeedsAnswer = lhs.activeRevision?.status == .needsClarification
                let rhsNeedsAnswer = rhs.activeRevision?.status == .needsClarification
                if lhsNeedsAnswer != rhsNeedsAnswer { return lhsNeedsAnswer }
                let lhsStartedAt = analysisProgressStore.analyses[lhs.id]?.startedAt ?? .distantPast
                let rhsStartedAt = analysisProgressStore.analyses[rhs.id]?.startedAt ?? .distantPast
                return lhsStartedAt > rhsStartedAt
            }
            .first
    }

    private func deleteMeal(_ meal: Meal) {
        MealAnalysisQueue.shared.cancel(for: meal.id, in: modelContext)
        do {
            let images = try SwiftDataMealRepository(context: modelContext).deleteMeal(meal)
            activeAnalysisMeal = nil
            Task {
                let storage = FileImageStorage()
                for image in images { await storage.deleteImage(image) }
            }
        } catch {
            AppLogger.persistence.error("Meal deletion failed")
        }
    }

    @MainActor
    private func duplicateMeal(_ meal: Meal) async throws {
        activeAnalysisMeal = try await MealDuplicationCoordinator(context: modelContext).duplicate(meal)
    }
}

private struct TodayDashboardContainer: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Meal.timestamp, order: .reverse) private var meals: [Meal]
    @Query(sort: \NutritionGoalPeriod.validFrom) private var goals: [NutritionGoalPeriod]
    @State private var selectedMeal: Meal?
    @State private var duplicateConfirmationMealID: UUID?
    private let imageStorage: any ImageStorageProviding = FileImageStorage()
    private let widgetSynchronizer = WidgetCalorieSnapshotSynchronizer()

    let isActive: Bool
    let onAddFood: () -> Void

    @ViewBuilder
    var body: some View {
        if isActive {
            TimelineView(.periodic(from: .now, by: 60 * 60)) { context in
                let snapshot = TodayDashboardBuilder.makeSnapshot(
                    for: context.date,
                    meals: meals,
                    goals: goals,
                    calendar: .autoupdatingCurrent
                )
                let widgetSnapshot = WidgetCalorieSnapshot(
                    dayStart: Calendar.autoupdatingCurrent.startOfDay(for: context.date),
                    energyKilocalories: snapshot.energy.consumed,
                    hasProvisionalValues: snapshot.hasProvisionalValues
                )
                TodayDashboardView(
                    snapshot: snapshot,
                    weeklySummary: WeeklyNutritionSummaryBuilder.makeSummary(
                        containing: context.date,
                        meals: meals,
                        goals: goals,
                        calendar: .autoupdatingCurrent
                    ),
                    onAddFood: onAddFood,
                    onRetryMeal: retryAnalysis,
                    onOpenMeal: openMeal
                )
                .task(id: widgetSnapshot) {
                    widgetSynchronizer.synchronize(widgetSnapshot)
                }
            }
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
            .onReceive(NotificationCenter.default.publisher(for: .quickCaptureRequested)) { _ in
                selectedMeal = nil
            }
        } else {
            Color.clear
                .accessibilityHidden(true)
        }
    }

    private func retryAnalysis(mealID: UUID) {
        guard let meal = meals.first(where: { $0.id == mealID }) else { return }
        Task { await MealAnalysisQueue.shared.analyze(meal, in: modelContext) }
    }

    private func openMeal(mealID: UUID) {
        selectedMeal = meals.first(where: { $0.id == mealID })
    }

    private func deleteMeal(_ meal: Meal) {
        MealAnalysisQueue.shared.cancel(for: meal.id, in: modelContext)
        do {
            let images = try SwiftDataMealRepository(context: modelContext).deleteMeal(meal)
            selectedMeal = nil
            Task {
                for image in images {
                    await imageStorage.deleteImage(image)
                }
            }
        } catch {
            AppLogger.persistence.error("Meal deletion failed")
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
}

#Preview {
    ContentView()
        .modelContainer(for: NutritionSchemaV2.models, inMemory: true)
}

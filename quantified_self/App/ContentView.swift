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
    @AppStorage("weeklySummaryReminderEnabled") private var weeklyReminderEnabled = false
    @Environment(\.scenePhase) private var scenePhase
    private let quickCaptureRequests = QuickCaptureRequestStore()
    private let weeklyReminderScheduler = WeeklySummaryNotificationScheduler()

    var body: some View {
        TabView(selection: $selectedSection) {
            Tab("Heute", systemImage: "sun.max.fill", value: .today) {
                TodayDashboardContainer {
                    mealCaptureMode = .standard
                }
            }

            Tab("Mahlzeiten", systemImage: "fork.knife", value: .meals) {
                MealsHistoryContainer()
            }

            Tab("Trends", systemImage: "chart.xyaxis.line", value: .trends) {
                NutritionTrendsContainer()
            }

            Tab("Einstellungen", systemImage: "gearshape", value: .settings) {
                OpenRouterSettingsView()
            }
        }
        .sheet(item: $mealCaptureMode) { mode in
            MealCaptureView(opensCameraOnAppear: mode == .camera)
        }
        .onAppear(perform: presentRequestedQuickCapture)
        .task {
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
}

private struct TodayDashboardContainer: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Meal.timestamp, order: .reverse) private var meals: [Meal]
    @Query(sort: \NutritionGoalPeriod.validFrom) private var goals: [NutritionGoalPeriod]
    @State private var selectedMeal: Meal?
    @State private var showsDinnerSuggestions = false
    private let imageStorage: any ImageStorageProviding = FileImageStorage()

    let onAddFood: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            TodayDashboardView(
                snapshot: TodayDashboardBuilder.makeSnapshot(
                    for: context.date,
                    meals: meals,
                    goals: goals,
                    calendar: .autoupdatingCurrent
                ),
                weeklySummary: WeeklyNutritionSummaryBuilder.makeSummary(
                    containing: context.date,
                    meals: meals,
                    goals: goals,
                    calendar: .autoupdatingCurrent
                ),
                onAddFood: onAddFood,
                onSuggestDinner: { showsDinnerSuggestions = true },
                onRetryMeal: retryAnalysis,
                onOpenMeal: openMeal
            )
        }
        .sheet(item: $selectedMeal) { meal in
            NavigationStack {
                MealReviewView(meal: meal) {
                    deleteMeal(meal)
                }
            }
        }
        .sheet(isPresented: $showsDinnerSuggestions) {
            DinnerSuggestionFlowView(
                snapshot: TodayDashboardBuilder.makeSnapshot(
                    for: .now,
                    meals: meals,
                    goals: goals,
                    calendar: .autoupdatingCurrent
                )
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickCaptureRequested)) { _ in
            selectedMeal = nil
            showsDinnerSuggestions = false
        }
    }

    private func retryAnalysis(mealID: UUID) {
        guard let meal = meals.first(where: { $0.id == mealID }) else { return }
        let coordinator = MealAnalysisCoordinator(context: modelContext)
        Task { await coordinator.analyze(meal) }
    }

    private func openMeal(mealID: UUID) {
        selectedMeal = meals.first(where: { $0.id == mealID })
    }

    private func deleteMeal(_ meal: Meal) {
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
}

#Preview {
    ContentView()
        .modelContainer(for: NutritionSchemaV2.models, inMemory: true)
}

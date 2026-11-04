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
    @State private var requestedTodayMealID: UUID?
    @State private var analysisProgressStore = MealAnalysisProgressStore.shared
    @AppStorage("weeklySummaryReminderEnabled") private var weeklyReminderEnabled = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    private let quickCaptureRequests = QuickCaptureRequestStore()
    private let weeklyReminderScheduler = WeeklySummaryNotificationScheduler()

    var body: some View {
        TabView(selection: $selectedSection) {
            Tab("Heute", systemImage: "sun.max.fill", value: .today) {
                TodayDashboardContainer(
                    isActive: selectedSection == .today,
                    requestedMealID: $requestedTodayMealID
                ) {
                    mealCaptureMode = .standard
                }
            }

            Tab("Mahlzeiten", systemImage: "fork.knife", value: .meals) {
                MealsHistoryContainer(isActive: selectedSection == .meals)
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
        .overlay(alignment: .topTrailing) {
            AnalysisActivityButton(
                progressStore: analysisProgressStore,
                action: openMostRelevantAnalysis
            )
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
        requestedTodayMealID = nil
        mealCaptureMode = nil
        Task {
            // Let the active detail route and any nested editor finish
            // dismissing before presenting the camera sheet.
            try? await Task.sleep(for: .milliseconds(800))
            guard activeQuickCaptureRequestID == requestID else { return }
            mealCaptureMode = .camera
        }
    }

    private func openMostRelevantAnalysis() {
        let meals = (try? modelContext.fetch(FetchDescriptor<Meal>())) ?? []
        let meal = meals
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
        guard let meal else { return }
        selectedSection = .today
        requestedTodayMealID = meal.id
    }
}

private struct AnalysisActivityButton: View {
    let progressStore: MealAnalysisProgressStore
    let action: () -> Void

    var body: some View {
        if !progressStore.analyses.isEmpty {
            Button(action: action) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(progressStore.analyses.count, format: .number)
                        .font(.caption.bold().monospacedDigit())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: .capsule)
                .shadow(radius: 4, y: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Laufende OpenRouter-Analysen: \(progressStore.analyses.count)")
            .accessibilityIdentifier("analysis.activity")
            .padding(.top, 6)
            .padding(.trailing, 12)
        }
    }
}

private struct TodayDashboardContainer: View {
    private struct RefreshID: Hashable {
        let presentationVersion: NutritionPresentationVersion
        let hour: Date
    }

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Meal.timestamp, order: .reverse) private var meals: [Meal]
    @Query(sort: \NutritionGoalPeriod.validFrom) private var goals: [NutritionGoalPeriod]
    @State private var navigationPath: [UUID] = []
    @State private var duplicateConfirmationMealID: UUID?
    @State private var snapshot: TodayDashboardSnapshot?
    @State private var weeklySummary: WeeklyNutritionSummary?
    @State private var lastRefreshID: RefreshID?
    private let imageStorage: any ImageStorageProviding = FileImageStorage()
    private let widgetSynchronizer = WidgetCalorieSnapshotSynchronizer()

    let isActive: Bool
    @Binding var requestedMealID: UUID?
    let onAddFood: () -> Void

    var body: some View {
        NavigationStack(path: $navigationPath) {
            TimelineView(.periodic(from: .now, by: 60 * 60)) { context in
                dashboardContent
                    .task(id: refreshID(for: context.date)) {
                        await refresh(for: context.date)
                    }
            }
            .navigationDestination(for: UUID.self, destination: mealDestination)
        }
        .onChange(of: requestedMealID) { _, mealID in
            guard let mealID, meals.contains(where: { $0.id == mealID }) else { return }
            navigationPath = [mealID]
            requestedMealID = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickCaptureRequested)) { _ in
            navigationPath.removeAll()
        }
    }

    @ViewBuilder
    private func mealDestination(_ mealID: UUID) -> some View {
        if let meal = meals.first(where: { $0.id == mealID }) {
            MealReviewView(
                meal: meal,
                showsDuplicateConfirmation: duplicateConfirmationMealID == meal.id,
                onDelete: deleteMeal,
                onDuplicate: duplicateMeal
            )
        } else {
            ContentUnavailableView("Mahlzeit nicht verfügbar", systemImage: "fork.knife")
        }
    }

    @ViewBuilder
    private var dashboardContent: some View {
        if let snapshot {
            TodayDashboardView(
                snapshot: snapshot,
                weeklySummary: weeklySummary,
                onAddFood: onAddFood,
                onRetryMeal: retryAnalysis,
                onOpenMeal: openMeal
            )
            .task(id: widgetSnapshot(for: snapshot)) {
                widgetSynchronizer.synchronize(widgetSnapshot(for: snapshot))
            }
        } else {
            ProgressView("Übersicht wird geladen …")
                .navigationTitle("Heute")
        }
    }

    private func refreshID(for date: Date) -> RefreshID? {
        guard isActive else { return nil }
        let calendar = Calendar.autoupdatingCurrent
        return RefreshID(
            presentationVersion: NutritionPresentationVersion(meals: meals, goals: goals),
            hour: calendar.dateInterval(of: .hour, for: date)?.start ?? date
        )
    }

    private func refresh(for date: Date) async {
        guard let refreshID = refreshID(for: date), refreshID != lastRefreshID else { return }
        await Task.yield()
        let presentation = TodayDashboardPresentationBuilder.makePresentation(
            for: date,
            meals: meals,
            goals: goals,
            calendar: .autoupdatingCurrent
        )
        guard !Task.isCancelled else { return }
        snapshot = presentation.snapshot
        weeklySummary = presentation.weeklySummary
        lastRefreshID = refreshID
    }

    private func widgetSnapshot(for snapshot: TodayDashboardSnapshot) -> WidgetCalorieSnapshot {
        WidgetCalorieSnapshot(
            dayStart: Calendar.autoupdatingCurrent.startOfDay(for: snapshot.date),
            energyKilocalories: snapshot.energy.consumed,
            hasProvisionalValues: snapshot.hasProvisionalValues
        )
    }

    private func retryAnalysis(mealID: UUID) {
        guard let meal = meals.first(where: { $0.id == mealID }) else { return }
        Task { await MealAnalysisQueue.shared.analyze(meal, in: modelContext) }
    }

    private func openMeal(mealID: UUID) {
        guard meals.contains(where: { $0.id == mealID }) else { return }
        navigationPath.append(mealID)
    }

    private func deleteMeal(_ meal: Meal) {
        MealAnalysisQueue.shared.cancel(for: meal.id, in: modelContext)
        do {
            let images = try SwiftDataMealRepository(context: modelContext).deleteMeal(meal)
            navigationPath.removeAll()
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
        navigationPath = [duplicate.id]
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

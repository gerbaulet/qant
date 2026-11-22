import OSLog
import SwiftData
import SwiftUI

struct ContentView: View {
    private enum AppSection: Hashable {
        case today
        case meals
        case insights
    }

    private enum MealCaptureMode: Identifiable, Hashable {
        case standard
        case camera

        var id: Self { self }
    }

    @State private var selectedSection: AppSection = .today
    @State private var mealCaptureMode: MealCaptureMode?
    @State private var showsSettings = false
    @State private var activeQuickCaptureRequestID: UUID?
    @State private var healthMetrics = HealthMetricsModel()
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
                    onAddFood: { mealCaptureMode = .standard },
                    onOpenSettings: { showsSettings = true }
                )
            }

            Tab("Mahlzeiten", systemImage: "fork.knife", value: .meals) {
                MealsHistoryContainer(
                    isActive: selectedSection == .meals,
                    onOpenSettings: { showsSettings = true }
                )
            }

            Tab("Auswertung", systemImage: "chart.xyaxis.line", value: .insights) {
                NutritionTrendsContainer(
                    isActive: selectedSection == .insights,
                    onOpenSettings: { showsSettings = true }
                )
            }
        }
        .environment(healthMetrics)
        .sheet(item: $mealCaptureMode) { mode in
            MealCaptureView(
                opensCameraOnAppear: true,
                isQuickCapture: mode == .camera
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsSettings) {
            OpenRouterSettingsView(
                isActive: showsSettings,
                onClose: { showsSettings = false }
            )
            .environment(healthMetrics)
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
        showsSettings = false
        Task {
            // Let the active detail route and any nested editor finish
            // dismissing before presenting the camera sheet.
            try? await Task.sleep(for: .milliseconds(800))
            guard activeQuickCaptureRequestID == requestID else { return }
            mealCaptureMode = .camera
        }
    }

}

private struct TodayDashboardContainer: View {
    private struct RefreshID: Hashable {
        let presentationVersion: NutritionPresentationVersion
        let hour: Date
        let healthDataVersion: Int
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(HealthMetricsModel.self) private var healthMetrics
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Meal.timestamp, order: .reverse) private var meals: [Meal]
    @Query(sort: \NutritionGoalPeriod.validFrom) private var goals: [NutritionGoalPeriod]
    @State private var navigationPath: [UUID] = []
    @State private var duplicateConfirmationMealID: UUID?
    @State private var snapshot: TodayDashboardSnapshot?
    @State private var weeklySummary: WeeklyNutritionSummary?
    @State private var intakeForecast: TodayIntakeForecast?
    @State private var energyBalance: DailyEnergyBalance?
    @State private var expenditureForecast: EnergyExpenditureForecast?
    @State private var energyTrend: TodayEnergyTrend?
    @State private var lastRefreshID: RefreshID?
    private let imageStorage: any ImageStorageProviding = FileImageStorage()
    private let widgetSynchronizer = WidgetCalorieSnapshotSynchronizer()

    let isActive: Bool
    let onAddFood: () -> Void
    let onOpenSettings: () -> Void

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
        .onReceive(NotificationCenter.default.publisher(for: .quickCaptureRequested)) { _ in
            navigationPath.removeAll()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await refreshCurrentDayEnergy()
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
                intakeForecast: intakeForecast,
                energyBalance: energyBalance,
                expenditureForecast: expenditureForecast,
                energyTrend: energyTrend,
                healthStatus: healthMetrics.energyStatus,
                onAddFood: onAddFood,
                onRetryMeal: retryAnalysis,
                onOpenMeal: openMeal,
                onOpenSettings: onOpenSettings
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
            hour: calendar.dateInterval(of: .hour, for: date)?.start ?? date,
            healthDataVersion: healthMetrics.dataVersion
        )
    }

    private func refresh(for date: Date) async {
        guard let refreshID = refreshID(for: date), refreshID != lastRefreshID else { return }
        await Task.yield()
        let calendar = Calendar.autoupdatingCurrent
        let forecastInterval = EnergyExpenditureForecastBuilder.historyInterval(
            for: date,
            calendar: calendar
        )
        let calibrationInterval = healthMetrics.personalCalibrationEnabled
            ? WeightBalanceComparisonBuilder.calibrationInterval(
                endingAt: date,
                calendar: calendar
            )
            : nil
        if healthMetrics.hasRequestedEnergyAccess, let forecastInterval {
            await healthMetrics.loadEnergy(
                from: min(calibrationInterval?.start ?? forecastInterval.start, forecastInterval.start),
                to: forecastInterval.end,
                calendar: calendar
            )
            await healthMetrics.loadHourlyEnergy(
                from: forecastInterval.start,
                to: forecastInterval.end,
                calendar: calendar
            )
        }
        if healthMetrics.hasRequestedWeightAccess, let calibrationInterval {
            await healthMetrics.loadWeights(
                from: calibrationInterval.start,
                to: calibrationInterval.end
            )
        }
        let presentation = TodayDashboardPresentationBuilder.makePresentation(
            for: date,
            meals: meals,
            goals: goals,
            calendar: calendar
        )
        guard !Task.isCancelled else { return }
        let currentExpenditure = healthMetrics.expenditure(for: date, calendar: calendar)
        let nextEnergyBalance = EnergyBalanceBuilder.makeBalance(
            for: date,
            meals: meals,
            expenditure: currentExpenditure,
            now: date,
            calendar: calendar
        )
        let nextExpenditureForecast: EnergyExpenditureForecast?
        let hourlyExpenditures: [HourlyEnergyExpenditure]
        if let forecastInterval {
            hourlyExpenditures = healthMetrics.hourlyExpenditures(within: forecastInterval)
            nextExpenditureForecast = EnergyExpenditureForecastBuilder.makeForecast(
                for: date,
                current: currentExpenditure,
                dailyExpenditures: healthMetrics.expenditures(within: forecastInterval),
                hourlyExpenditures: hourlyExpenditures,
                calendar: calendar
            )
        } else {
            hourlyExpenditures = []
            nextExpenditureForecast = nil
        }
        let personalDailyBalanceAdjustment = calibrationInterval.flatMap {
            personalDailyBalanceAdjustment(
                within: $0,
                now: date,
                calendar: calendar
            )
        }
        snapshot = presentation.snapshot
        weeklySummary = presentation.weeklySummary
        intakeForecast = presentation.intakeForecast
        energyBalance = nextEnergyBalance
        expenditureForecast = nextExpenditureForecast
        energyTrend = TodayEnergyTrendBuilder.makeTrend(
            intakeTrend: presentation.intakeTrend,
            currentExpenditure: currentExpenditure,
            expenditureForecast: nextExpenditureForecast,
            hourlyExpenditures: hourlyExpenditures,
            dailyBalanceAdjustmentKilocalories: personalDailyBalanceAdjustment,
            now: date,
            calendar: calendar
        )
        lastRefreshID = refreshID
    }

    private func refreshCurrentDayEnergy() async {
        guard healthMetrics.hasRequestedEnergyAccess else { return }
        let calendar = Calendar.autoupdatingCurrent
        guard let dayInterval = calendar.dateInterval(of: .day, for: .now) else { return }
        await healthMetrics.loadEnergy(
            from: dayInterval.start,
            to: dayInterval.end,
            calendar: calendar,
            force: true
        )
        await healthMetrics.loadHourlyEnergy(
            from: dayInterval.start,
            to: dayInterval.end,
            calendar: calendar,
            force: true
        )
    }

    private func personalDailyBalanceAdjustment(
        within calibrationInterval: DateInterval,
        now: Date,
        calendar: Calendar
    ) -> Double? {
        let balances = EnergyBalanceBuilder.makeBalances(
            within: calibrationInterval,
            meals: meals,
            expenditures: healthMetrics.expenditures(within: calibrationInterval),
            now: now,
            calendar: calendar
        )
        return WeightBalanceComparisonBuilder.makeComparison(
            measurements: healthMetrics.weights(within: calibrationInterval),
            balances: balances,
            comparisonStart: calibrationInterval.start,
            now: now,
            calendar: calendar,
            calibrationEnabled: healthMetrics.personalCalibrationEnabled
        )
        .dailyBalanceAdjustmentKilocalories
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

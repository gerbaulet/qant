import SwiftData
import SwiftUI

struct NutritionTrendsContainer: View {
    private struct RefreshID: Hashable {
        let presentationVersion: NutritionPresentationVersion
        let hour: Date
        let range: NutritionTrendRange
        let forecastStrategy: IntakeForecastStrategy
    }

    private struct BalanceRefreshID: Hashable {
        let presentationRefreshID: RefreshID
        let healthDataVersion: Int
    }

    private struct HealthLoadID: Hashable {
        let hour: Date
        let range: NutritionTrendRange
        let hasRequestedEnergyAccess: Bool
        let hasRequestedWeightAccess: Bool
        let personalCalibrationEnabled: Bool
    }

    @Environment(HealthMetricsModel.self) private var healthMetrics
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Meal.timestamp) private var meals: [Meal]
    @Query(sort: \NutritionGoalPeriod.validFrom) private var goals: [NutritionGoalPeriod]
    @AppStorage(IntakeForecastPreferences.mealAwareEnabledKey)
    private var mealAwareIntakeForecastEnabled = false
    @State private var range = NutritionTrendRange.month
    @State private var snapshot: NutritionTrendsSnapshot?
    @State private var balances: [DailyEnergyBalance] = []
    @State private var weightComparison: WeightBalanceComparison?
    @State private var currentDayForecastBalanceKilocalories: Double?
    @State private var balanceRange: NutritionTrendRange?
    @State private var lastRefreshID: RefreshID?
    @State private var lastBalanceRefreshID: BalanceRefreshID?
    let isActive: Bool
    let onOpenSettings: () -> Void

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 60 * 60)) { context in
                insightsContent
                    .task(id: refreshID(for: context.date)) {
                        await refresh(for: context.date)
                    }
                    .task(id: balanceRefreshID(for: context.date)) {
                        await refreshBalances(for: context.date)
                    }
                    .task(id: healthLoadID(for: context.date)) {
                        await loadHealthData(for: context.date)
                    }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Auswertung")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onOpenSettings) {
                        Label("Einstellungen", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("settings.open")
                }
            }
        }
    }

    private var insightsContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: QuantLayout.sectionSpacing) {
                rangePicker
                EnergyBalanceTrendsView(
                    balances: balanceRange == range ? balances : [],
                    healthStatus: healthMetrics.energyStatus,
                    weightStatus: healthMetrics.weightStatus,
                    weightComparison: balanceRange == range ? weightComparison : nil,
                    currentDayForecastBalanceKilocalories: balanceRange == range
                        ? currentDayForecastBalanceKilocalories
                        : nil,
                    onOpenSettings: onOpenSettings
                )
                if let snapshot, snapshot.range == range {
                    NutritionTrendsView(snapshot: snapshot)
                } else {
                    QuantCard {
                        ProgressView("Nährwerte werden geladen …")
                            .frame(maxWidth: .infinity, minHeight: 140)
                    }
                }
            }
            .padding(.horizontal, QuantLayout.pageInset)
            .padding(.vertical, QuantLayout.sectionSpacing)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var rangePicker: some View {
        Picker("Zeitraum", selection: $range) {
            Text("30 Tage").tag(NutritionTrendRange.month)
            Text("3 Monate").tag(NutritionTrendRange.threeMonths)
            Text("12 Monate").tag(NutritionTrendRange.year)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("insights.range")
    }

    private func refreshID(for date: Date) -> RefreshID? {
        guard isActive else { return nil }
        let calendar = Calendar.autoupdatingCurrent
        return RefreshID(
            presentationVersion: NutritionPresentationVersion(meals: meals, goals: goals),
            hour: calendar.dateInterval(of: .hour, for: date)?.start ?? date,
            range: range,
            forecastStrategy: forecastStrategy
        )
    }

    private func balanceRefreshID(for date: Date) -> BalanceRefreshID? {
        guard let presentationRefreshID = refreshID(for: date),
              presentationRefreshID == lastRefreshID else { return nil }
        return BalanceRefreshID(
            presentationRefreshID: presentationRefreshID,
            healthDataVersion: healthMetrics.dataVersion
        )
    }

    private func healthLoadID(for date: Date) -> HealthLoadID? {
        guard isActive, scenePhase == .active else { return nil }
        let calendar = Calendar.autoupdatingCurrent
        return HealthLoadID(
            hour: calendar.dateInterval(of: .hour, for: date)?.start ?? date,
            range: range,
            hasRequestedEnergyAccess: healthMetrics.hasRequestedEnergyAccess,
            hasRequestedWeightAccess: healthMetrics.hasRequestedWeightAccess,
            personalCalibrationEnabled: healthMetrics.personalCalibrationEnabled
        )
    }

    private func refresh(for date: Date) async {
        guard let refreshID = refreshID(for: date), refreshID != lastRefreshID else { return }
        await Task.yield()
        let nextSnapshot = NutritionTrendsBuilder.makeSnapshot(
            for: date,
            range: range,
            nutrient: .energy,
            meals: meals,
            goals: goals,
            calendar: .autoupdatingCurrent,
            forecastStrategy: forecastStrategy
        )
        guard !Task.isCancelled else { return }
        snapshot = nextSnapshot
        lastRefreshID = refreshID
    }

    private func refreshBalances(for date: Date) async {
        guard let refreshID = balanceRefreshID(for: date),
              refreshID != lastBalanceRefreshID,
              let interval = balanceInterval(for: date),
              let intakeTrend = snapshot?.dailyCumulativeTrend else { return }
        await Task.yield()
        let calendar = Calendar.autoupdatingCurrent
        let calibrationInterval = HealthMetricsQueryPlanner.calibrationInterval(
            endingAt: date,
            enabled: healthMetrics.personalCalibrationEnabled,
            hasRequestedWeightAccess: healthMetrics.hasRequestedWeightAccess,
            calendar: calendar
        )
        let forecastInterval = EnergyExpenditureForecastBuilder.historyInterval(
            for: date,
            calendar: calendar
        )
        let weightInterval = HealthMetricsQueryPlanner.covering([
            interval,
            calibrationInterval,
        ])
        guard !Task.isCancelled else { return }
        let historyInterval = weightInterval ?? interval
        let historicalBalances = EnergyBalanceBuilder.makeBalances(
            within: historyInterval,
            meals: meals,
            expenditures: healthMetrics.expenditures(within: historyInterval),
            now: date,
            calendar: calendar
        )
        let nextBalances = EnergyBalanceBuilder.selectBalances(
            from: historicalBalances,
            within: interval
        )
        let nextWeightComparison = WeightBalanceComparisonBuilder.makeComparison(
            measurements: healthMetrics.weights(within: historyInterval),
            balances: historicalBalances,
            comparisonStart: interval.start,
            now: date,
            calendar: calendar,
            calibrationEnabled: healthMetrics.personalCalibrationEnabled
        )
        let currentExpenditure = healthMetrics.expenditure(for: date, calendar: calendar)
        let expenditureForecast = forecastInterval.flatMap {
            EnergyExpenditureForecastBuilder.makeForecast(
                for: date,
                current: currentExpenditure,
                dailyExpenditures: healthMetrics.expenditures(within: $0),
                hourlyExpenditures: healthMetrics.hourlyExpenditures(within: $0),
                calendar: calendar
            )
        }
        let nextCurrentDayForecastBalance = PersonalEnergyBalanceCalculator
            .forecastBalanceKilocalories(
                intakeKilocalories: intakeTrend.forecastPoints.last?.value,
                expenditureKilocalories: expenditureForecast?.totalKilocalories,
                dailyAdjustmentKilocalories: nextWeightComparison.dailyBalanceAdjustmentKilocalories
            )
        balances = nextBalances
        weightComparison = nextWeightComparison
        currentDayForecastBalanceKilocalories = nextCurrentDayForecastBalance
        balanceRange = range
        lastBalanceRefreshID = refreshID
    }

    private func loadHealthData(for date: Date) async {
        guard healthLoadID(for: date) != nil,
              let interval = balanceInterval(for: date) else { return }
        let calendar = Calendar.autoupdatingCurrent
        let calibrationInterval = HealthMetricsQueryPlanner.calibrationInterval(
            endingAt: date,
            enabled: healthMetrics.personalCalibrationEnabled,
            hasRequestedWeightAccess: healthMetrics.hasRequestedWeightAccess,
            calendar: calendar
        )
        let energyInterval = HealthMetricsQueryPlanner.covering([
            interval,
            EnergyExpenditureForecastBuilder.historyInterval(
                for: date,
                calendar: calendar
            ),
            calibrationInterval,
        ])
        let weightInterval = HealthMetricsQueryPlanner.covering([
            interval,
            calibrationInterval,
        ])
        if healthMetrics.hasRequestedEnergyAccess, let energyInterval {
            await healthMetrics.loadEnergy(
                from: energyInterval.start,
                to: energyInterval.end,
                calendar: calendar
            )
        }
        if healthMetrics.hasRequestedWeightAccess, let weightInterval {
            await healthMetrics.loadWeights(
                from: weightInterval.start,
                to: weightInterval.end
            )
        }
    }

    private var forecastStrategy: IntakeForecastStrategy {
        IntakeForecastPreferences.strategy(
            mealAwareEnabled: mealAwareIntakeForecastEnabled
        )
    }

    private func balanceInterval(for date: Date) -> DateInterval? {
        NutritionTrendsBuilder.dateInterval(
            for: date,
            range: range,
            calendar: .autoupdatingCurrent
        )
    }
}

struct NutritionTrendsView: View {
    let snapshot: NutritionTrendsSnapshot

    private let displayedNutrients: [NutrientIdentifier] = [
        .energy, .protein, .carbohydrates, .fat, .fiber,
    ]

    var body: some View {
        let comparison = snapshot.periodComparison
        QuantCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Nährwerte")
                    .font(.headline)
                Text("Durchschnitt pro erfasstem Tag · Vergleich mit dem vorherigen Zeitraum")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if comparison.current.hasProvisionalValues || comparison.previous.hasProvisionalValues {
                    Text("~ Enthält vorläufige Schätzwerte aus offenen Rückfragen.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                ForEach(displayedNutrients, id: \.self) { nutrient in
                    comparisonRow(nutrient, comparison: comparison)
                    if nutrient != displayedNutrients.last { Divider() }
                }

                Divider()
                LabeledContent("Erfasste Tage") {
                    Text("\(comparison.current.trackedDayCount)/\(comparison.current.calendarDayCount)")
                }
                LabeledContent("Tage im Kalorienziel") {
                    Text("\(comparison.current.daysAtOrBelowEnergyTarget)")
                }
                LabeledContent("Tage über Kalorienziel") {
                    Text("\(comparison.current.daysAboveEnergyTarget)")
                }
            }
        }
        .accessibilityIdentifier("trends.comparisonCard")
    }

    private func comparisonRow(
        _ nutrient: NutrientIdentifier,
        comparison: NutritionPeriodComparison
    ) -> some View {
        let current = comparison.current.average(for: nutrient)
        let change = comparison.percentChange(for: nutrient)
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(nutrient.trendTitle)
                    .font(.subheadline.bold())
                Text("Ø pro erfasstem Tag")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(comparison.current.hasProvisionalValues ? "~" : "")\(formatted(current)) \(nutrient.trendUnit.rawValue)")
                    .font(.subheadline.monospacedDigit())
                if let change {
                    Text(
                        ((comparison.current.hasProvisionalValues || comparison.previous.hasProvisionalValues) ? "~" : "") +
                            change.formatted(.number.sign(strategy: .always()).precision(.fractionLength(1))) + " %"
                    )
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func formatted(_ value: Double?) -> String {
        guard let value else { return "–" }
        return value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0)))
    }
}

private extension NutrientIdentifier {
    var trendTitle: String {
        switch self {
        case .energy: "Kalorien"
        case .protein: "Protein"
        case .carbohydrates: "Kohlenhydrate"
        case .fat: "Fett"
        case .fiber: "Ballaststoffe"
        default: rawValue
        }
    }

    var trendUnit: NutrientUnit {
        self == .energy ? .kilocalorie : .gram
    }
}

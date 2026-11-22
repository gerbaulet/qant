import SwiftData
import SwiftUI

struct NutritionTrendsContainer: View {
    private struct RefreshID: Hashable {
        let presentationVersion: NutritionPresentationVersion
        let hour: Date
        let range: NutritionTrendRange
    }

    private struct BalanceRefreshID: Hashable {
        let presentationVersion: NutritionPresentationVersion
        let hour: Date
        let range: NutritionTrendRange
        let healthDataVersion: Int
    }

    @Environment(HealthMetricsModel.self) private var healthMetrics
    @Query(sort: \Meal.timestamp) private var meals: [Meal]
    @Query(sort: \NutritionGoalPeriod.validFrom) private var goals: [NutritionGoalPeriod]
    @State private var range = NutritionTrendRange.month
    @State private var snapshot: NutritionTrendsSnapshot?
    @State private var balances: [DailyEnergyBalance] = []
    @State private var weightComparison: WeightBalanceComparison?
    @State private var currentDayForecastBalanceKilocalories: Double?
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
                    balances: balances,
                    healthStatus: healthMetrics.energyStatus,
                    weightStatus: healthMetrics.weightStatus,
                    weightComparison: weightComparison,
                    currentDayForecastBalanceKilocalories: currentDayForecastBalanceKilocalories,
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
            Text("7 Tage").tag(NutritionTrendRange.week)
            Text("30 Tage").tag(NutritionTrendRange.month)
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
            range: range
        )
    }

    private func balanceRefreshID(for date: Date) -> BalanceRefreshID? {
        guard isActive else { return nil }
        let calendar = Calendar.autoupdatingCurrent
        return BalanceRefreshID(
            presentationVersion: NutritionPresentationVersion(meals: meals, goals: goals),
            hour: calendar.dateInterval(of: .hour, for: date)?.start ?? date,
            range: range,
            healthDataVersion: healthMetrics.dataVersion
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
            calendar: .autoupdatingCurrent
        )
        guard !Task.isCancelled else { return }
        snapshot = nextSnapshot
        lastRefreshID = refreshID
    }

    private func refreshBalances(for date: Date) async {
        guard let refreshID = balanceRefreshID(for: date),
              refreshID != lastBalanceRefreshID,
              let interval = balanceInterval(for: date) else { return }
        let calendar = Calendar.autoupdatingCurrent
        let calibrationInterval = WeightBalanceComparisonBuilder.calibrationInterval(
            endingAt: date,
            calendar: calendar
        )
        let forecastInterval = EnergyExpenditureForecastBuilder.historyInterval(
            for: date,
            calendar: calendar
        )
        let queryStart = min(interval.start, calibrationInterval.start)
        if healthMetrics.hasRequestedEnergyAccess {
            await healthMetrics.loadEnergy(
                from: queryStart,
                to: interval.end,
                calendar: calendar
            )
            if let forecastInterval {
                await healthMetrics.loadHourlyEnergy(
                    from: forecastInterval.start,
                    to: forecastInterval.end,
                    calendar: calendar
                )
            }
        }
        if healthMetrics.hasRequestedWeightAccess {
            await healthMetrics.loadWeights(from: queryStart, to: interval.end)
        }
        guard !Task.isCancelled else { return }
        let nextBalances = EnergyBalanceBuilder.makeBalances(
            within: interval,
            meals: meals,
            expenditures: healthMetrics.expenditures(within: interval),
            now: date,
            calendar: calendar
        )
        let historyInterval = DateInterval(start: queryStart, end: interval.end)
        let historicalBalances = EnergyBalanceBuilder.makeBalances(
            within: historyInterval,
            meals: meals,
            expenditures: healthMetrics.expenditures(within: historyInterval),
            now: date,
            calendar: calendar
        )
        let nextWeightComparison = WeightBalanceComparisonBuilder.makeComparison(
            measurements: healthMetrics.weights(within: historyInterval),
            balances: historicalBalances,
            comparisonStart: interval.start,
            now: date,
            calendar: calendar,
            calibrationEnabled: healthMetrics.personalCalibrationEnabled
        )
        let todayPresentation = TodayDashboardPresentationBuilder.makePresentation(
            for: date,
            meals: meals,
            goals: goals,
            calendar: calendar
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
                intakeKilocalories: todayPresentation.intakeForecast?.energyKilocalories,
                expenditureKilocalories: expenditureForecast?.totalKilocalories,
                dailyAdjustmentKilocalories: nextWeightComparison.dailyBalanceAdjustmentKilocalories
            )
        balances = nextBalances
        weightComparison = nextWeightComparison
        currentDayForecastBalanceKilocalories = nextCurrentDayForecastBalance
        lastBalanceRefreshID = refreshID
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

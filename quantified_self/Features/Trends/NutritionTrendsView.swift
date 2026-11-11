import Charts
import SwiftData
import SwiftUI

private enum InsightsSection: String, CaseIterable, Identifiable {
    case balance
    case nutrients

    var id: Self { self }

    var title: String {
        switch self {
        case .balance: "Bilanz"
        case .nutrients: "Nährwerte"
        }
    }
}

struct NutritionTrendsContainer: View {
    private struct RefreshID: Hashable {
        let presentationVersion: NutritionPresentationVersion
        let hour: Date
        let range: NutritionTrendRange
        let nutrient: NutrientIdentifier
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
    @State private var section = InsightsSection.balance
    @State private var range = NutritionTrendRange.month
    @State private var balanceRange = NutritionTrendRange.month
    @State private var nutrient = NutrientIdentifier.energy
    @State private var snapshot: NutritionTrendsSnapshot?
    @State private var balances: [DailyEnergyBalance] = []
    @State private var lastRefreshID: RefreshID?
    @State private var lastBalanceRefreshID: BalanceRefreshID?
    let isActive: Bool
    let onOpenSettings: () -> Void

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 60 * 60)) { context in
                VStack(spacing: 0) {
                    Picker("Auswertung", selection: $section) {
                        ForEach(InsightsSection.allCases) { section in
                            Text(section.title).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, QuantLayout.pageInset)
                    .padding(.top, 8)
                    .accessibilityIdentifier("insights.section")

                    insightsContent
                }
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

    @ViewBuilder
    private var insightsContent: some View {
        if section == .balance {
            EnergyBalanceTrendsView(
                balances: balances,
                range: $balanceRange,
                healthStatus: healthMetrics.energyStatus,
                onOpenSettings: onOpenSettings
            )
        } else if let snapshot, snapshot.range == range, snapshot.nutrient == nutrient {
            NutritionTrendsView(
                snapshot: snapshot,
                range: $range,
                nutrient: $nutrient
            )
        } else {
            ProgressView("Auswertung wird geladen …")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func refreshID(for date: Date) -> RefreshID? {
        guard isActive, section == .nutrients else { return nil }
        let calendar = Calendar.autoupdatingCurrent
        return RefreshID(
            presentationVersion: NutritionPresentationVersion(meals: meals, goals: goals),
            hour: calendar.dateInterval(of: .hour, for: date)?.start ?? date,
            range: range,
            nutrient: nutrient
        )
    }

    private func balanceRefreshID(for date: Date) -> BalanceRefreshID? {
        guard isActive, section == .balance else { return nil }
        let calendar = Calendar.autoupdatingCurrent
        return BalanceRefreshID(
            presentationVersion: NutritionPresentationVersion(meals: meals, goals: []),
            hour: calendar.dateInterval(of: .hour, for: date)?.start ?? date,
            range: balanceRange,
            healthDataVersion: healthMetrics.dataVersion
        )
    }

    private func refresh(for date: Date) async {
        guard let refreshID = refreshID(for: date), refreshID != lastRefreshID else { return }
        await Task.yield()
        let nextSnapshot = NutritionTrendsBuilder.makeSnapshot(
            for: date,
            range: range,
            nutrient: nutrient,
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
        if healthMetrics.hasRequestedEnergyAccess {
            await healthMetrics.loadEnergy(
                from: interval.start,
                to: interval.end,
                calendar: .autoupdatingCurrent
            )
        }
        guard !Task.isCancelled else { return }
        balances = EnergyBalanceBuilder.makeBalances(
            within: interval,
            meals: meals,
            expenditures: healthMetrics.expenditures(within: interval),
            now: date,
            calendar: .autoupdatingCurrent
        )
        lastBalanceRefreshID = refreshID
    }

    private func balanceInterval(for date: Date) -> DateInterval? {
        let calendar = Calendar.autoupdatingCurrent
        let period: Calendar.Component
        switch balanceRange {
        case .day, .week: period = .weekOfYear
        case .month: period = .month
        case .year: period = .year
        }
        guard let interval = calendar.dateInterval(of: period, for: date),
              let tomorrow = calendar.date(
                byAdding: .day,
                value: 1,
                to: calendar.startOfDay(for: date)
              ) else { return nil }
        return DateInterval(start: interval.start, end: min(interval.end, tomorrow))
    }
}

struct NutritionTrendsView: View {
    let snapshot: NutritionTrendsSnapshot
    @Binding var range: NutritionTrendRange
    @Binding var nutrient: NutrientIdentifier

    private let displayedNutrients: [NutrientIdentifier] = [
        .energy, .protein, .carbohydrates, .fat, .fiber,
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: QuantLayout.sectionSpacing) {
                controls
                chartCard
                periodComparisonCard
            }
            .padding(.horizontal, QuantLayout.pageInset)
            .padding(.vertical, QuantLayout.sectionSpacing)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("Zeitraum", selection: $range) {
                Text("Tag").tag(NutritionTrendRange.day)
                Text("Woche").tag(NutritionTrendRange.week)
                Text("Monat").tag(NutritionTrendRange.month)
                Text("Jahr").tag(NutritionTrendRange.year)
            }
            .pickerStyle(.segmented)

            Picker("Nährwert", selection: $nutrient) {
                ForEach(displayedNutrients, id: \.self) { nutrient in
                    Text(nutrient.trendTitle).tag(nutrient)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var chartCard: some View {
        if range == .day {
            dailyChartCard
        } else {
            periodChartCard
        }
    }

    private var periodChartCard: some View {
        let actualPoints = snapshot.points.filter { !$0.isForecast }
        let forecastPoint = snapshot.points.first { $0.isForecast }
        let forecastSegment = forecastPoint.map { point in
            actualPoints.last.map { [$0, point] } ?? [point]
        } ?? []
        return QuantCard(style: .hero) {
            VStack(alignment: .leading, spacing: 14) {
                Text(nutrient.trendTitle)
                    .font(.headline)
                if snapshot.points.contains(where: \.isProvisional) {
                    provisionalNotice
                }
                if snapshot.points.isEmpty {
                    ContentUnavailableView(
                        "Keine auswertbaren Daten",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Analysierte Mahlzeiten erscheinen hier als Tageswerte.")
                    )
                    .frame(minHeight: 220)
                } else {
                    Chart {
                        ForEach(actualPoints) { point in
                            LineMark(
                                x: .value("Tag", point.date),
                                y: .value(nutrient.trendTitle, point.value),
                                series: .value("Verlauf", "Ist")
                            )
                            .interpolationMethod(.catmullRom)
                            PointMark(
                                x: .value("Tag", point.date),
                                y: .value(nutrient.trendTitle, point.value)
                            )
                        }
                        ForEach(forecastSegment) { point in
                            LineMark(
                                x: .value("Tag", point.date),
                                y: .value(nutrient.trendTitle, point.value),
                                series: .value("Verlauf", "Prognose")
                            )
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [7, 5]))
                        }
                        if let forecastPoint {
                            PointMark(
                                x: .value("Tag", forecastPoint.date),
                                y: .value(nutrient.trendTitle, forecastPoint.value)
                            )
                            .symbol {
                                forecastSymbol
                            }
                        }
                    }
                    .foregroundStyle(.blue)
                    .frame(height: 240)
                    .accessibilityLabel("Verlauf für \(nutrient.trendTitle)")
                    .accessibilityValue(chartAccessibilityValue)
                }
            }
        }
        .accessibilityIdentifier("trends.chartCard")
    }

    private var dailyChartCard: some View {
        let trend = snapshot.dailyCumulativeTrend
        return QuantCard(style: .hero) {
            VStack(alignment: .leading, spacing: 14) {
                Text(nutrient.trendTitle)
                    .font(.headline)
                if trend.hasProvisionalValues {
                    provisionalNotice
                }

                if !trend.hasActualData && trend.averageDayCount == 0 {
                    ContentUnavailableView(
                        "Noch nicht genug Vergleichstage",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Für eine Prognose braucht Quant mindestens drei frühere Tage mit analysierten Mahlzeiten.")
                    )
                    .frame(minHeight: 220)
                } else {
                    HStack(spacing: 18) {
                        chartLegend(title: "Heute", dashed: false, color: .blue)
                        if !trend.forecastPoints.isEmpty {
                            chartLegend(title: "Prognose", dashed: true, color: .blue)
                        }
                        if trend.averageDayCount > 0 {
                            chartLegend(
                                title: "Ø \(trend.averageDayCount) Tage",
                                dashed: true,
                                color: .orange
                            )
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Chart {
                        ForEach(trend.actualPoints) { point in
                            LineMark(
                                x: .value("Uhrzeit", point.hour),
                                y: .value(nutrient.trendTitle, point.value),
                                series: .value("Verlauf", "Heute")
                            )
                            .interpolationMethod(.stepEnd)
                            .foregroundStyle(.blue)
                            .lineStyle(StrokeStyle(lineWidth: 3))
                        }
                        ForEach(trend.averagePoints) { point in
                            LineMark(
                                x: .value("Uhrzeit", point.hour),
                                y: .value(nutrient.trendTitle, point.value),
                                series: .value("Verlauf", "Durchschnitt")
                            )
                            .interpolationMethod(.stepEnd)
                            .foregroundStyle(.orange)
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [7, 5]))
                        }
                        ForEach(trend.forecastPoints) { point in
                            LineMark(
                                x: .value("Uhrzeit", point.hour),
                                y: .value(nutrient.trendTitle, point.value),
                                series: .value("Verlauf", "Prognose")
                            )
                            .interpolationMethod(.stepEnd)
                            .foregroundStyle(.blue)
                            .lineStyle(StrokeStyle(lineWidth: 3, dash: [7, 5]))
                        }
                        if let forecast = trend.forecastPoints.last {
                            PointMark(
                                x: .value("Uhrzeit", forecast.hour),
                                y: .value(nutrient.trendTitle, forecast.value)
                            )
                            .foregroundStyle(.blue)
                            .symbol {
                                forecastSymbol
                            }
                            .annotation(position: .top, alignment: .trailing) {
                                forecastLabel(forecast.value)
                            }
                        }
                    }
                    .chartXScale(domain: 0...24)
                    .chartXAxis {
                        AxisMarks(values: [0, 4, 8, 12, 16, 20, 24]) { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel {
                                if let hour = value.as(Int.self) {
                                    Text("\(hour)")
                                }
                            }
                        }
                    }
                    .frame(height: 240)
                    .accessibilityLabel("Kumulativer Tagesverlauf für \(nutrient.trendTitle)")
                    .accessibilityValue(dailyChartAccessibilityValue)

                    if trend.forecastPoints.isEmpty {
                        Text("Noch nicht genug Vergleichstage für eine Prognose.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityIdentifier("trends.chartCard")
    }

    private func chartLegend(title: String, dashed: Bool, color: Color) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: 2, dash: dashed ? [5, 4] : [])
                )
                .frame(width: 26, height: 2)
            Text(title)
        }
    }

    private var forecastSymbol: some View {
        ZStack {
            Circle().fill(.background)
            Circle().stroke(.blue, lineWidth: 2)
        }
        .frame(width: 10, height: 10)
    }

    private func forecastLabel(_ value: Double) -> some View {
        Text("~\(formatted(value))")
            .font(.caption.bold().monospacedDigit())
            .foregroundStyle(.blue)
    }

    private var periodComparisonCard: some View {
        let comparison = snapshot.periodComparison
        return QuantCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(comparisonTitle)
                    .font(.title2.bold())
                Text(comparisonDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if comparison.current.hasProvisionalValues || comparison.previous.hasProvisionalValues {
                    provisionalNotice
                }

                ForEach(displayedNutrients, id: \.self) { nutrient in
                    comparisonRow(nutrient, comparison: comparison)
                    if nutrient != displayedNutrients.last { Divider() }
                }

                Divider()
                LabeledContent("Erfasste Tage") {
                    Text("\(comparison.current.trackedDayCount)/\(comparison.current.calendarDayCount) · vorher \(comparison.previous.trackedDayCount)/\(comparison.previous.calendarDayCount)")
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
        let previous = comparison.previous.average(for: nutrient)
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
                Text("\(comparison.previous.hasProvisionalValues ? "~" : "")\(formatted(previous)) → \(comparison.current.hasProvisionalValues ? "~" : "")\(formatted(current)) \(nutrient.trendUnit.rawValue)")
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

    private var comparisonTitle: String {
        range == .day ? "Tagesvergleich" : "\(range.dayCount)-Tage-Vergleich"
    }

    private var comparisonDescription: String {
        if range == .day {
            return "Gestern im Vergleich mit vorgestern"
        }
        return "Letzte \(range.dayCount) abgeschlossene Tage im Vergleich mit den \(range.dayCount) Tagen davor"
    }

    private func formatted(_ value: Double?) -> String {
        guard let value else { return "–" }
        return value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0)))
    }

    private var provisionalNotice: some View {
        Text("~ Enthält vorläufige Schätzwerte aus offenen Rückfragen.")
            .font(.caption)
            .foregroundStyle(.orange)
    }

    private var chartAccessibilityValue: String {
        snapshot.points.map { point in
            let date = point.date.formatted(
                .dateTime.day().month().locale(Locale(identifier: "de_DE"))
            )
            let prefix = point.isForecast ? "Prognose " : point.isProvisional ? "Vorläufig " : ""
            return "\(date): \(prefix)\(formatted(point.value)) \(nutrient.trendUnit.rawValue)"
        }.joined(separator: ", ")
    }

    private var dailyChartAccessibilityValue: String {
        let trend = snapshot.dailyCumulativeTrend
        let actual = trend.actualPoints.last?.value ?? 0
        let average = trend.averagePoints.last?.value
        var description = "Heute: \(formatted(actual)) \(nutrient.trendUnit.rawValue)"
        if let forecast = trend.forecastPoints.last?.value {
            description += ", Prognose: \(formatted(forecast)) \(nutrient.trendUnit.rawValue)"
        }
        if let average {
            description += ", Durchschnitt aus \(trend.averageDayCount) Tagen: \(formatted(average)) \(nutrient.trendUnit.rawValue)"
        }
        return description
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

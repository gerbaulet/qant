import Charts
import SwiftData
import SwiftUI

struct NutritionTrendsContainer: View {
    @Query(sort: \Meal.timestamp) private var meals: [Meal]
    @Query(sort: \NutritionGoalPeriod.validFrom) private var goals: [NutritionGoalPeriod]
    @State private var range = NutritionTrendRange.month
    @State private var nutrient = NutrientIdentifier.energy

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60 * 60)) { context in
            NutritionTrendsView(
                snapshot: NutritionTrendsBuilder.makeSnapshot(
                    for: context.date,
                    range: range,
                    nutrient: nutrient,
                    meals: meals,
                    goals: goals,
                    calendar: .autoupdatingCurrent
                ),
                range: $range,
                nutrient: $nutrient
            )
        }
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
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    controls
                    chartCard
                    monthlyComparisonCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Trends")
        }
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
        VStack(alignment: .leading, spacing: 14) {
            Text(nutrient.trendTitle)
                .font(.headline)
            if snapshot.points.isEmpty {
                ContentUnavailableView(
                    "Keine bestätigten Daten",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Bestätigte Mahlzeiten erscheinen hier als Tageswerte.")
                )
                .frame(minHeight: 220)
            } else {
                Chart(snapshot.points) { point in
                    LineMark(
                        x: .value("Tag", point.date),
                        y: .value(nutrient.trendTitle, point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    PointMark(
                        x: .value("Tag", point.date),
                        y: .value(nutrient.trendTitle, point.value)
                    )
                }
                .foregroundStyle(.blue)
                .frame(height: 240)
                .accessibilityLabel("Verlauf für \(nutrient.trendTitle)")
                .accessibilityValue(chartAccessibilityValue)
            }
        }
        .padding(18)
        .background(.background, in: .rect(cornerRadius: 18))
    }

    private var dailyChartCard: some View {
        let trend = snapshot.dailyCumulativeTrend
        return VStack(alignment: .leading, spacing: 14) {
            Text(nutrient.trendTitle)
                .font(.headline)

            if !trend.hasActualData && trend.averageDayCount == 0 {
                ContentUnavailableView(
                    "Keine bestätigten Daten",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Bestätigte Mahlzeiten erscheinen hier im Tagesverlauf.")
                )
                .frame(minHeight: 220)
            } else {
                HStack(spacing: 18) {
                    chartLegend(title: "Heute", dashed: false, color: .blue)
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
            }
        }
        .padding(18)
        .background(.background, in: .rect(cornerRadius: 18))
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

    private var monthlyComparisonCard: some View {
        let comparison = snapshot.monthlyComparison
        return VStack(alignment: .leading, spacing: 14) {
            Text("Monatsvergleich")
                .font(.title2.bold())
            Text("Monat bis heute im Vergleich mit demselben Zeitraum des Vormonats")
                .font(.footnote)
                .foregroundStyle(.secondary)

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
        .padding(18)
        .background(.background, in: .rect(cornerRadius: 18))
    }

    private func comparisonRow(
        _ nutrient: NutrientIdentifier,
        comparison: MonthlyNutritionComparison
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
                Text("\(formatted(previous)) → \(formatted(current)) \(nutrient.trendUnit.rawValue)")
                    .font(.subheadline.monospacedDigit())
                if let change {
                    Text(change.formatted(.number.sign(strategy: .always()).precision(.fractionLength(1))) + " %")
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

    private var chartAccessibilityValue: String {
        snapshot.points.map { point in
            let date = point.date.formatted(
                .dateTime.day().month().locale(Locale(identifier: "de_DE"))
            )
            return "\(date): \(formatted(point.value)) \(nutrient.trendUnit.rawValue)"
        }.joined(separator: ", ")
    }

    private var dailyChartAccessibilityValue: String {
        let trend = snapshot.dailyCumulativeTrend
        let actual = trend.actualPoints.last?.value ?? 0
        let average = trend.averagePoints.last?.value
        var description = "Heute: \(formatted(actual)) \(nutrient.trendUnit.rawValue)"
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

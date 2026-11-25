import Charts
import SwiftUI

struct IntakeForecastComparisonView: View {
    @Environment(\.calendar) private var calendar
    @State private var showsTechnicalDetails = false

    let meals: [Meal]
    let mealAwareEnabled: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let comparison = IntakeForecastComparisonBuilder.makeComparison(
                for: context.date,
                meals: meals,
                calendar: calendar
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    currentContext(at: context.date)
                    actualValueCard(comparison)

                    if comparison.difference != nil {
                        forecastContent(comparison)
                    } else {
                        unavailableContent(comparison)
                    }

                    dataBasis(comparison)
                    technicalDetails

                    Label(
                        "Beide Verfahren werden vollständig auf diesem iPhone berechnet.",
                        systemImage: "lock.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .accessibilityIdentifier("settings.intakeForecastComparison.screen")
        }
        .navigationTitle("Aufnahmeprognose")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func currentContext(at date: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Heute")
                    .font(.title2.bold())
                Text("Stand \(date.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(mealAwareEnabled ? "Mahlzeitenbewusst aktiv" : "Zeitbasiert aktiv")
                .font(.caption.bold())
                .foregroundStyle(mealAwareEnabled ? Color.blue : Color.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    (mealAwareEnabled ? Color.blue : Color.orange).opacity(0.12),
                    in: Capsule()
                )
        }
    }

    private func actualValueCard(_ comparison: IntakeForecastComparison) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Bis jetzt erfasst")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(energyText(
                comparison.actualEnergyKilocalories,
                isProvisional: comparison.actualHasProvisionalValues
            ))
            .font(.system(.title, design: .rounded, weight: .bold))
            .monospacedDigit()
            .accessibilityIdentifier("settings.intakeForecastComparison.actual")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func forecastContent(_ comparison: IntakeForecastComparison) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                forecastValueCard(
                    title: "Mahlzeitenbewusst",
                    value: comparison.mealAwareEnergyKilocalories,
                    color: .blue,
                    identifier: "settings.intakeForecastComparison.mealAware",
                    isProvisional: comparison.forecastHasProvisionalValues
                )
                forecastValueCard(
                    title: "Zeitbasiert",
                    value: comparison.historicalRemainderEnergyKilocalories,
                    color: .orange,
                    identifier: "settings.intakeForecastComparison.timeBased",
                    isProvisional: comparison.forecastHasProvisionalValues
                )
            }

            VStack(spacing: 10) {
                forecastValueCard(
                    title: "Mahlzeitenbewusst",
                    value: comparison.mealAwareEnergyKilocalories,
                    color: .blue,
                    identifier: "settings.intakeForecastComparison.mealAware",
                    isProvisional: comparison.forecastHasProvisionalValues
                )
                forecastValueCard(
                    title: "Zeitbasiert",
                    value: comparison.historicalRemainderEnergyKilocalories,
                    color: .orange,
                    identifier: "settings.intakeForecastComparison.timeBased",
                    isProvisional: comparison.forecastHasProvisionalValues
                )
            }
        }

        differenceSummary(comparison)

        VStack(alignment: .leading, spacing: 12) {
            Text("Tagesverlauf")
                .font(.headline)

            forecastLegend
            comparisonChart(comparison)
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private func forecastValueCard(
        title: String,
        value: Double?,
        color: Color,
        identifier: String,
        isProvisional: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.map {
                energyText($0, isProvisional: isProvisional)
            } ?? "— kcal")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(color)
                .monospacedDigit()
                .accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func differenceSummary(_ comparison: IntakeForecastComparison) -> some View {
        switch comparison.difference {
        case .equal:
            Label(
                "Beide Verfahren ergeben heute dieselbe Prognose.",
                systemImage: "equal.circle.fill"
            )
            .accessibilityIdentifier("settings.intakeForecastComparison.equal")
            .forecastComparisonSummaryStyle(color: .secondary)
        case let .mealAwareLower(difference):
            Label(
                "Die mahlzeitenbewusste Prognose liegt heute \(wholeNumber(difference)) kcal niedriger.",
                systemImage: "arrow.down.circle.fill"
            )
            .accessibilityIdentifier("settings.intakeForecastComparison.difference")
            .forecastComparisonSummaryStyle(color: .blue)
        case let .mealAwareHigher(difference):
            Label(
                "Die mahlzeitenbewusste Prognose liegt heute \(wholeNumber(difference)) kcal höher.",
                systemImage: "arrow.up.circle.fill"
            )
            .accessibilityIdentifier("settings.intakeForecastComparison.difference")
            .forecastComparisonSummaryStyle(color: .blue)
        case nil:
            EmptyView()
        }
    }

    private var forecastLegend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                ForecastComparisonLegendItem(title: "Erfasst", color: .primary, dash: [])
                ForecastComparisonLegendItem(
                    title: "Mahlzeitenbewusst",
                    color: .blue,
                    dash: [7, 5]
                )
                ForecastComparisonLegendItem(
                    title: "Zeitbasiert",
                    color: .orange,
                    dash: [2, 5]
                )
            }

            VStack(alignment: .leading, spacing: 7) {
                ForecastComparisonLegendItem(title: "Erfasst", color: .primary, dash: [])
                ForecastComparisonLegendItem(
                    title: "Mahlzeitenbewusst",
                    color: .blue,
                    dash: [7, 5]
                )
                ForecastComparisonLegendItem(
                    title: "Zeitbasiert",
                    color: .orange,
                    dash: [2, 5]
                )
            }
        }
    }

    private func comparisonChart(_ comparison: IntakeForecastComparison) -> some View {
        Chart {
            if let currentHour = comparison.mealAwarePoints.first?.hour {
                RuleMark(x: .value("Jetzt", currentHour))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("Jetzt")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }

            ForEach(comparison.actualPoints) { point in
                LineMark(
                    x: .value("Uhrzeit", point.hour),
                    y: .value("Erfasst", point.value),
                    series: .value("Reihe", "Erfasst")
                )
                .interpolationMethod(.stepEnd)
                .foregroundStyle(.primary)
                .lineStyle(StrokeStyle(lineWidth: 3))
            }

            ForEach(comparison.historicalRemainderPoints) { point in
                LineMark(
                    x: .value("Uhrzeit", point.hour),
                    y: .value("Zeitbasiert", point.value),
                    series: .value("Reihe", "Zeitbasiert")
                )
                .interpolationMethod(.stepEnd)
                .foregroundStyle(.orange)
                .lineStyle(StrokeStyle(
                    lineWidth: mealAwareEnabled ? 2 : 3,
                    dash: [2, 5]
                ))
            }

            ForEach(comparison.mealAwarePoints) { point in
                LineMark(
                    x: .value("Uhrzeit", point.hour),
                    y: .value("Mahlzeitenbewusst", point.value),
                    series: .value("Reihe", "Mahlzeitenbewusst")
                )
                .interpolationMethod(.stepEnd)
                .foregroundStyle(.blue)
                .lineStyle(StrokeStyle(
                    lineWidth: mealAwareEnabled ? 3 : 2,
                    dash: [7, 5]
                ))
            }
        }
        .chartXScale(domain: 0...24)
        .chartYScale(domain: 0...chartUpperBound(comparison))
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 24]) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let hour = value.as(Int.self) {
                        Text("\(hour)")
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(wholeNumber(number))
                    }
                }
            }
        }
        .frame(height: 250)
        .accessibilityIdentifier("settings.intakeForecastComparison.chart")
        .accessibilityLabel("Heutige Aufnahme und Prognosen")
        .accessibilityValue(chartAccessibilityValue(comparison))
    }

    private func unavailableContent(_ comparison: IntakeForecastComparison) -> some View {
        ContentUnavailableView(
            "Noch nicht genug Vergleichsdaten",
            systemImage: "chart.xyaxis.line",
            description: Text(
                "Für beide Prognosen benötigt Quant mindestens drei frühere erfasste Tage. Vorhanden: \(comparison.historicalDayCount)."
            )
        )
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("settings.intakeForecastComparison.unavailable")
    }

    private func dataBasis(_ comparison: IntakeForecastComparison) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Datengrundlage")
                .font(.headline)
            LabeledContent(
                "Frühere erfasste Tage",
                value: "\(comparison.historicalDayCount)"
            )
            Text("Gleiche Wochentage zählen doppelt. Quant betrachtet höchstens die letzten 90 erfassten Tage.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private var technicalDetails: some View {
        DisclosureGroup("Technische Details", isExpanded: $showsTechnicalDetails) {
            VStack(alignment: .leading, spacing: 8) {
                Text("• Eine Mahlzeit kommt nur infrage, wenn ihre Uhrzeit höchstens fünf Stunden abweicht und die kleinere Kalorienmenge mindestens 30 % der größeren beträgt.")
                Text("• Die Ähnlichkeitswertung besteht zu 50 % aus der Uhrzeit, zu 35 % aus der Kalorienmenge und zu 15 % aus der Position im Tagesablauf. Mindestens 55 % sind erforderlich.")
                Text("• Jede heutige und jede frühere Mahlzeit wird höchstens einmal zugeordnet.")
                Text("• Noch nicht zugeordnete, bereits verspätete Mahlzeiten bleiben mit einer über drei Stunden exponentiell sinkenden Wahrscheinlichkeit in der Prognose.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("settings.intakeForecastComparison.technicalDetails")
    }

    private func chartUpperBound(_ comparison: IntakeForecastComparison) -> Double {
        let maximum = (
            comparison.actualPoints +
                comparison.historicalRemainderPoints +
                comparison.mealAwarePoints
        )
        .map(\.value)
        .max() ?? 0
        return max(500, (maximum / 500).rounded(.up) * 500)
    }

    private func chartAccessibilityValue(_ comparison: IntakeForecastComparison) -> String {
        let actual = wholeNumber(comparison.actualEnergyKilocalories)
        let mealAware = comparison.mealAwareEnergyKilocalories.map(wholeNumber) ?? "nicht verfügbar"
        let timeBased = comparison.historicalRemainderEnergyKilocalories.map(wholeNumber) ??
            "nicht verfügbar"
        return "Bisher \(actual) Kilokalorien, mahlzeitenbewusst \(mealAware) Kilokalorien, zeitbasiert \(timeBased) Kilokalorien"
    }

    private func energyText(_ value: Double, isProvisional: Bool) -> String {
        "\(isProvisional ? "~" : "")\(wholeNumber(value)) kcal"
    }

    private func wholeNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }
}

private struct ForecastComparisonLegendItem: View {
    let title: String
    let color: Color
    let dash: [CGFloat]

    var body: some View {
        HStack(spacing: 5) {
            ForecastComparisonLegendLine()
                .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dash))
                .frame(width: 20, height: 3)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct ForecastComparisonLegendLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

private extension View {
    func forecastComparisonSummaryStyle(color: Color) -> some View {
        font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }
}

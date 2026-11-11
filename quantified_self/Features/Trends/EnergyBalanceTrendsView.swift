import Charts
import SwiftUI

struct EnergyBalanceTrendsView: View {
    let balances: [DailyEnergyBalance]
    @Binding var range: NutritionTrendRange
    let healthStatus: HealthDataStatus
    let onOpenSettings: () -> Void

    private var displayedBalances: [DailyEnergyBalance] {
        balances.filter(\.canDescribeBalance)
    }

    private var completedBalances: [DailyEnergyBalance] {
        balances.filter { $0.completeness == .complete && !$0.isCurrentDay }
    }

    private var averageBalance: Double? {
        let values = completedBalances.compactMap(\.balanceKilocalories)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: QuantLayout.sectionSpacing) {
                rangePicker
                content
            }
            .padding(.horizontal, QuantLayout.pageInset)
            .padding(.vertical, QuantLayout.sectionSpacing)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var rangePicker: some View {
        Picker("Zeitraum", selection: $range) {
            Text("Woche").tag(NutritionTrendRange.week)
            Text("Monat").tag(NutritionTrendRange.month)
            Text("Jahr").tag(NutritionTrendRange.year)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("balance.range")
    }

    @ViewBuilder
    private var content: some View {
        switch healthStatus {
        case .notRequested:
            setupCard
        case .loading where displayedBalances.isEmpty:
            ProgressView("Apple-Health-Daten werden geladen …")
                .frame(maxWidth: .infinity, minHeight: 240)
        case .unavailable:
            unavailableCard(
                title: "Apple Health ist nicht verfügbar",
                description: "Die Energiebilanz benötigt ein Gerät mit Apple Health."
            )
        case .failed:
            unavailableCard(
                title: "Daten konnten nicht geladen werden",
                description: "Versuche es später erneut oder prüfe den Zugriff in den Einstellungen."
            )
        default:
            if displayedBalances.isEmpty {
                unavailableCard(
                    title: "Noch keine vollständige Bilanz",
                    description: emptyDescription
                )
            } else {
                summaryCard
                chartCard
                interpretationCard
                completenessCard
            }
        }
    }

    private var setupCard: some View {
        QuantCard(style: .hero) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Energiebilanz mit Apple Health", systemImage: "heart.text.square")
                    .font(.title3.bold())
                Text("Quant verrechnet deine geschätzte Aufnahme mit Aktivitäts- und Ruheenergie. Alle Health-Daten bleiben lokal auf deinem Gerät.")
                    .foregroundStyle(.secondary)
                Button("Apple Health einrichten", action: onOpenSettings)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("balance.setupHealth")
            }
        }
    }

    private func unavailableCard(title: String, description: String) -> some View {
        QuantCard(style: .hero) {
            ContentUnavailableView(
                title,
                systemImage: "chart.bar.xaxis",
                description: Text(description)
            )
            .frame(minHeight: 220)
        }
    }

    private var summaryCard: some View {
        QuantCard(style: .hero) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Durchschnittliche Tagesbilanz")
                    .font(.headline)
                if let averageBalance {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("≈ \(wholeNumber(abs(averageBalance))) kcal")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .foregroundStyle(balanceColor(averageBalance))
                        Text(averageBalance <= 0 ? "Defizit" : "Überschuss")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text("Aus \(completedBalances.count) vollständigen, abgeschlossenen Tagen")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Für einen Durchschnitt braucht Quant mindestens einen vollständigen abgeschlossenen Tag.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("balance.summary")
    }

    private var chartCard: some View {
        QuantCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Defizit und Überschuss")
                    .font(.headline)
                HStack(spacing: 16) {
                    Label("Defizit", systemImage: "square.fill")
                        .foregroundStyle(.blue)
                    Label("Überschuss", systemImage: "square.fill")
                        .foregroundStyle(.orange)
                }
                .font(.caption)

                Chart {
                    RuleMark(y: .value("Ausgeglichen", 0))
                        .foregroundStyle(.secondary)
                    ForEach(displayedBalances) { balance in
                        if let value = balance.balanceKilocalories {
                            BarMark(
                                x: .value("Tag", balance.date, unit: .day),
                                y: .value("Bilanz", value)
                            )
                            .foregroundStyle(value < 0 ? Color.blue : Color.orange)
                            .opacity(balance.isCurrentDay || balance.completeness != .complete ? 0.55 : 1)
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(number.formatted(.number.precision(.fractionLength(0))))
                            }
                        }
                    }
                }
                .frame(height: 250)
                .accessibilityLabel("Energiebilanz im gewählten Zeitraum")
                .accessibilityValue(chartAccessibilityValue)

                if displayedBalances.contains(where: { $0.isCurrentDay || $0.completeness != .complete }) {
                    Text("Hell dargestellte Werte sind Zwischenstände oder enthalten vorläufige Mahlzeitenschätzungen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("balance.chart")
    }

    private var interpretationCard: some View {
        QuantCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Einordnung", systemImage: "lightbulb")
                    .font(.headline)
                Text(interpretationText)
                Text("Die Werte sind Schätzungen und keine medizinische Beratung.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var completenessCard: some View {
        QuantCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Datenqualität")
                    .font(.headline)
                LabeledContent("Auswertbare Tage", value: "\(displayedBalances.count) von \(balances.count)")
                if case let .limited(since) = healthStatus {
                    Text("Apple Health stellt Quant Daten ab \(since.formatted(date: .abbreviated, time: .omitted)) bereit.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Tage ohne Mahlzeit oder ohne vollständige Aktivitäts- und Ruheenergie werden nicht als Defizit oder Überschuss gewertet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var emptyDescription: String {
        if healthStatus == .noData {
            return "Apple Health liefert für diesen Zeitraum noch keine vollständige Aktivitäts- und Ruheenergie."
        }
        return "Erfasse Mahlzeiten und trage deine Apple Watch, damit Quant Aufnahme und Verbrauch vergleichen kann."
    }

    private var interpretationText: String {
        guard let averageBalance else {
            return "Einzelne Tageswerte schwanken stark. Quant zeigt eine verlässlichere Einordnung, sobald mehrere vollständige Tage vorliegen."
        }
        if abs(averageBalance) < 100 {
            return "Aufnahme und Verbrauch liegen im Mittel ungefähr auf demselben Niveau."
        }
        if averageBalance < 0 {
            return "Im betrachteten Zeitraum lag im Mittel ein geschätztes Defizit vor. Entscheidend ist der längerfristige Verlauf, nicht ein einzelner Tag."
        }
        return "Im betrachteten Zeitraum lag im Mittel ein geschätzter Überschuss vor. Einzelne Tage sind normal; beobachte den längerfristigen Verlauf."
    }

    private var chartAccessibilityValue: String {
        guard let averageBalance else { return "Keine vollständigen abgeschlossenen Tage" }
        let direction = averageBalance <= 0 ? "Defizit" : "Überschuss"
        return "Durchschnittlich \(wholeNumber(abs(averageBalance))) Kilokalorien \(direction) pro vollständigem Tag"
    }

    private func balanceColor(_ value: Double) -> Color {
        abs(value) < 100 ? .secondary : (value < 0 ? .blue : .orange)
    }

    private func wholeNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }
}

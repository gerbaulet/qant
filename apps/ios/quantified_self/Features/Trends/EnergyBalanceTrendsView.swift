import Charts
import SwiftUI

struct EnergyBalanceTrendsView: View {
    let balances: [DailyEnergyBalance]
    let healthStatus: HealthDataStatus
    let weightStatus: HealthDataStatus
    let weightComparison: WeightBalanceComparison?
    let currentDayForecastBalanceKilocalories: Double?
    let onOpenSettings: () -> Void

    private var displayedBalances: [DailyEnergyBalance] {
        balances.filter(\.canDescribeBalance)
    }

    private var personalDailyAdjustment: Double? {
        weightComparison?.dailyBalanceAdjustmentKilocalories
    }

    private var averageBalance: Double? {
        PersonalEnergyBalanceCalculator.averageBalanceKilocalories(
            for: balances,
            dailyAdjustmentKilocalories: personalDailyAdjustment
        )
    }

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        switch healthStatus {
        case .notRequested:
            setupCard
        case .loading where displayedBalances.isEmpty:
            QuantCard(style: .hero) {
                ProgressView("Apple-Health-Daten werden geladen …")
                    .frame(maxWidth: .infinity, minHeight: 180)
            }
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
                overviewCard
                detailsCard
            }
        }
    }

    private var setupCard: some View {
        QuantCard(style: .hero) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Energiebilanz mit Apple Health", systemImage: "heart.text.square")
                    .font(.title3.bold())
                Text("Quant vergleicht deine geschätzte Aufnahme mit Aktivitäts- und Ruheenergie. Alle Health-Daten bleiben lokal auf deinem Gerät.")
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
            .frame(minHeight: 180)
        }
    }

    private var overviewCard: some View {
        QuantCard(style: .hero) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Deine Energiebilanz")
                        .font(.headline)
                    Spacer()
                    if personalDailyAdjustment != nil {
                        Text("PERSÖNLICH ANGEPASST")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.blue.opacity(0.12), in: .capsule)
                    }
                }

                if let averageBalance {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("≈ \(wholeNumber(abs(averageBalance))) kcal")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .foregroundStyle(balanceColor(averageBalance))
                        Text(averageBalance <= 0 ? "Defizit" : "Überschuss")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text("durchschnittlich pro vollständigem Tag")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Für einen Durchschnitt braucht Quant mindestens einen vollständigen abgeschlossenen Tag.")
                        .foregroundStyle(.secondary)
                }

                Chart {
                    RuleMark(y: .value("Ausgeglichen", 0))
                        .foregroundStyle(.secondary)
                    ForEach(displayedBalances) { balance in
                        if let value = displayedBalanceKilocalories(for: balance) {
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
                .frame(height: 220)
                .accessibilityLabel("Energiebilanz im gewählten Zeitraum")
                .accessibilityValue(chartAccessibilityValue)
                .accessibilityIdentifier("balance.chart")

                if let comparison = readyWeightComparison {
                    Divider()
                    weightValue(
                        title: "Gewichtstrend",
                        value: comparison.observedChangeKilograms
                    )
                    Text("Beobachteter Trend aus deinen verfügbaren Apple-Health-Gewichtsdaten im gewählten Zeitraum.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(interpretationText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("balance.summary")
    }

    private var detailsCard: some View {
        QuantCard {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Auswertbare Tage", value: "\(displayedBalances.count) von \(balances.count)")
                    LabeledContent(
                        "Darstellung",
                        value: personalDailyAdjustment == nil ? "Erfasste Schätzung" : "Persönlich angepasst"
                    )
                    if let adjustment = personalDailyAdjustment {
                        LabeledContent(
                            "Persönliche Korrektur",
                            value: "\(signedKilocalories(adjustment))/Tag"
                        )
                        Text("Quant addiert die Korrektur zu jedem vollständigen Tag. Ein positiver Wert verschiebt die Bilanz in Richtung Überschuss, ein negativer in Richtung Defizit. Erfasste Mahlzeiten und Health-Werte bleiben unverändert.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    weightDetails
                    Text("Tage ohne Mahlzeit oder ohne vollständige Aktivitäts- und Ruheenergie werden nicht gewertet. Die Werte sind Schätzungen und keine medizinische Beratung.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 10)
            } label: {
                Label("Berechnung & Datenqualität", systemImage: "info.circle")
                    .font(.headline)
            }
        }
        .accessibilityIdentifier("balance.details")
    }

    @ViewBuilder
    private var weightDetails: some View {
        switch weightStatus {
        case .notRequested:
            Button("Gewichtsdaten für persönliche Einordnung verbinden", action: onOpenSettings)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("balance.setupWeight")
        case .loading:
            ProgressView("Gewichtsdaten werden geladen …")
        case .noData:
            Text("Keine Gewichtsdaten verfügbar.")
                .foregroundStyle(.secondary)
        case .unavailable:
            Text("Gewichtsdaten sind auf diesem Gerät nicht verfügbar.")
                .foregroundStyle(.secondary)
        case .failed:
            Text("Gewichtsdaten konnten nicht geladen werden.")
                .foregroundStyle(.secondary)
        default:
            if let comparison = weightComparison {
                switch comparison.readiness {
                case .ready:
                    EmptyView()
                case let .needsWeights(current, required, spanDays, requiredSpanDays):
                    Text("Gewichtstrend wird aufgebaut: \(current)/\(required) Gewichtstage, \(spanDays)/\(requiredSpanDays) Tage abgedeckt.")
                        .foregroundStyle(.secondary)
                }
                switch comparison.calibrationStatus {
                case .disabled:
                    EmptyView()
                case let .collecting(
                    weightCount,
                    requiredWeightCount,
                    balanceDayCount,
                    requiredBalanceDayCount,
                    spanDays,
                    requiredSpanDays
                ):
                    Text("Persönliche Kalibrierung wird aufgebaut: \(weightCount)/\(requiredWeightCount) Gewichtstage, \(balanceDayCount)/\(requiredBalanceDayCount) vollständige Bilanztage und \(spanDays)/\(requiredSpanDays) Tage abgedeckt.")
                        .foregroundStyle(.secondary)
                case let .unavailable(reason):
                    Text(reason)
                        .foregroundStyle(.secondary)
                case .ready:
                    Text("Die persönliche Korrektur wird aus bis zu 12 Monaten deines Gewichts- und Bilanzverlaufs abgeleitet. Weil der Gewichtstrend in die Kalibrierung einfließt, berechnet Quant daraus keine separate Gewichtserwartung.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var readyWeightComparison: WeightBalanceComparison? {
        guard let weightComparison, weightComparison.readiness == .ready else { return nil }
        return weightComparison
    }

    private func weightValue(title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(signedKilograms(value))
                .font(.title3.bold().monospacedDigit())
        }
    }

    private func displayedBalanceKilocalories(for balance: DailyEnergyBalance) -> Double? {
        PersonalEnergyBalanceCalculator.balanceKilocalories(
            for: balance,
            dailyAdjustmentKilocalories: personalDailyAdjustment,
            currentDayForecastKilocalories: currentDayForecastBalanceKilocalories
        )
    }

    private var emptyDescription: String {
        if healthStatus == .noData {
            return "Apple Health liefert für diesen Zeitraum noch keine vollständige Aktivitäts- und Ruheenergie."
        }
        return "Erfasse Mahlzeiten und trage deine Apple Watch, damit Quant Aufnahme und Verbrauch vergleichen kann."
    }

    private var interpretationText: String {
        guard let averageBalance else {
            return "Einzelne Tageswerte schwanken stark. Quant ordnet den Verlauf ein, sobald mehrere vollständige Tage vorliegen."
        }
        if abs(averageBalance) < 100 {
            return "Aufnahme und Verbrauch liegen im Mittel ungefähr auf demselben Niveau."
        }
        if averageBalance < 0 {
            return "Im gewählten Zeitraum lag im Mittel ein geschätztes Defizit vor. Entscheidend ist der längerfristige Verlauf."
        }
        return "Im gewählten Zeitraum lag im Mittel ein geschätzter Überschuss vor. Entscheidend ist der längerfristige Verlauf."
    }

    private var chartAccessibilityValue: String {
        guard let averageBalance else { return "Keine vollständigen abgeschlossenen Tage" }
        let direction = averageBalance <= 0 ? "Defizit" : "Überschuss"
        let source = personalDailyAdjustment == nil ? "Erfasste Schätzung" : "Persönlich angepasst"
        return "\(source), durchschnittlich \(wholeNumber(abs(averageBalance))) Kilokalorien \(direction) pro vollständigem Tag"
    }

    private func signedKilocalories(_ value: Double) -> String {
        "\(value.formatted(.number.sign(strategy: .always()).precision(.fractionLength(0)))) kcal"
    }

    private func signedKilograms(_ value: Double?) -> String {
        guard let value else { return "— kg" }
        return "\(value.formatted(.number.sign(strategy: .always()).precision(.fractionLength(1)))) kg"
    }

    private func balanceColor(_ value: Double) -> Color {
        abs(value) < 100 ? .secondary : (value < 0 ? .blue : .orange)
    }

    private func wholeNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }
}

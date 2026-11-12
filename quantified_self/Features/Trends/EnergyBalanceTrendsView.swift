import Charts
import SwiftUI

struct EnergyBalanceTrendsView: View {
    let balances: [DailyEnergyBalance]
    @Binding var range: NutritionTrendRange
    let healthStatus: HealthDataStatus
    let weightStatus: HealthDataStatus
    let weightComparison: WeightBalanceComparison?
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
                weightComparisonCard
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

    @ViewBuilder
    private var weightComparisonCard: some View {
        switch weightStatus {
        case .notRequested:
            QuantCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Bilanz mit Gewichtstrend prüfen", systemImage: "scalemass")
                        .font(.headline)
                    Text("Mit Gewichtsdaten aus Apple Health kann Quant vergleichen, ob die längerfristige Veränderung ungefähr zur berechneten Energiebilanz passt.")
                        .foregroundStyle(.secondary)
                    Button("Gewichtsdaten verbinden", action: onOpenSettings)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("balance.setupWeight")
                }
            }
        case .loading:
            QuantCard {
                ProgressView("Gewichtsdaten werden geladen …")
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        case .noData:
            weightUnavailableCard(
                title: "Keine Gewichtsdaten verfügbar",
                description: "Prüfe den Zugriff und deine Gewichtseinträge in Apple Health."
            )
        case .unavailable:
            weightUnavailableCard(
                title: "Gewichtsdaten nicht verfügbar",
                description: "Apple Health ist auf diesem Gerät nicht verfügbar."
            )
        case .failed:
            weightUnavailableCard(
                title: "Gewichtsdaten konnten nicht geladen werden",
                description: "Versuche es später erneut oder aktualisiere die Daten in den Einstellungen."
            )
        default:
            if let weightComparison {
                switch weightComparison.readiness {
                case .ready:
                    readyWeightComparisonCard(weightComparison)
                case let .needsWeights(current, required, spanDays, requiredSpanDays):
                    weightCollectingCard(
                        title: "Gewichtstrend wird aufgebaut",
                        description: "\(current) von \(required) Gewichtstagen · \(spanDays) von \(requiredSpanDays) Tagen abgedeckt"
                    )
                case let .needsBalanceDays(current, required):
                    weightCollectingCard(
                        title: "Bilanzvergleich wird aufgebaut",
                        description: "\(current) von \(required) vollständigen Bilanztagen im gewählten Zeitraum"
                    )
                }
            } else {
                weightCollectingCard(
                    title: "Gewichtstrend wird vorbereitet",
                    description: "Quant lädt die Daten für den gewählten Zeitraum."
                )
            }
        }
    }

    private func readyWeightComparisonCard(
        _ comparison: WeightBalanceComparison
    ) -> some View {
        QuantCard(style: .hero) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Bilanz und Gewicht", systemImage: "scalemass")
                        .font(.headline)
                    Spacer()
                    Text(comparison.usesPersonalCalibration ? "PERSÖNLICH" : "STANDARD")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(comparison.usesPersonalCalibration ? .blue : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.secondary.opacity(0.12), in: .capsule)
                }

                HStack(spacing: 18) {
                    chartLegend(title: "Gewichtstrend", color: .primary, dashed: false)
                    chartLegend(
                        title: comparison.usesPersonalCalibration ? "Persönlich erwartet" : "Aus Bilanz erwartet",
                        color: .blue,
                        dashed: true
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Chart {
                    ForEach(comparison.dailyWeights) { measurement in
                        PointMark(
                            x: .value("Tag", measurement.date),
                            y: .value("Gewicht", measurement.kilograms)
                        )
                        .foregroundStyle(.secondary.opacity(0.55))
                    }
                    ForEach(comparison.observedTrend) { point in
                        LineMark(
                            x: .value("Tag", point.date),
                            y: .value("Gewicht", point.kilograms),
                            series: .value("Reihe", "Gewichtstrend")
                        )
                        .foregroundStyle(.primary)
                        .lineStyle(StrokeStyle(lineWidth: 3))
                    }
                    ForEach(comparison.expectedTrend) { point in
                        LineMark(
                            x: .value("Tag", point.date),
                            y: .value("Gewicht", point.kilograms),
                            series: .value("Reihe", "Erwartung")
                        )
                        .foregroundStyle(.blue)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(number.formatted(.number.precision(.fractionLength(1))))
                            }
                        }
                    }
                }
                .frame(height: 250)
                .accessibilityLabel("Gewichtstrend im Vergleich zur Energiebilanz")
                .accessibilityValue(weightComparisonAccessibilityValue(comparison))

                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Beobachtet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(signedKilograms(comparison.observedChangeKilograms))
                            .font(.title3.bold().monospacedDigit())
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Erwartet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(signedKilograms(comparison.expectedChangeKilograms))
                            .font(.title3.bold().monospacedDigit())
                    }
                }

                Text(weightInterpretation(comparison))
                    .font(.subheadline)

                calibrationStatusView(comparison.calibrationStatus)

                Text("Kurzfristige Wasser- und Verdauungsschwankungen können den Gewichtstrend deutlich verschieben. Quant bewertet deshalb keine einzelnen Messungen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("balance.weightComparison")
    }

    private func weightUnavailableCard(title: String, description: String) -> some View {
        QuantCard {
            ContentUnavailableView(
                title,
                systemImage: "scalemass",
                description: Text(description)
            )
            .frame(minHeight: 150)
        }
    }

    private func weightCollectingCard(title: String, description: String) -> some View {
        QuantCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: "scalemass")
                    .font(.headline)
                Text(description)
                Text(weightComparisonRequirementText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func calibrationStatusView(_ status: PersonalCalibrationStatus) -> some View {
        switch status {
        case .disabled:
            Label("Persönliche Kalibrierung ist ausgeschaltet.", systemImage: "person.crop.circle.badge.xmark")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case let .collecting(weightCount, requiredWeightCount, balanceDayCount, requiredBalanceDayCount, spanDays, requiredSpanDays):
            VStack(alignment: .leading, spacing: 4) {
                Label("Persönliches Modell lernt noch", systemImage: "person.crop.circle.badge.clock")
                    .font(.footnote.weight(.semibold))
                Text("\(weightCount)/\(requiredWeightCount) Gewichtstage · \(balanceDayCount)/\(requiredBalanceDayCount) Bilanztage · \(spanDays)/\(requiredSpanDays) Tage Zeitraum")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case let .unavailable(reason):
            Label(reason, systemImage: "person.crop.circle.badge.questionmark")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .ready:
            Label("Persönliches Modell aus mindestens sechs Wochen Verlauf aktiv", systemImage: "person.crop.circle.badge.checkmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.blue)
        }
    }

    private func chartLegend(title: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [5, 4] : []))
                .frame(width: 24, height: 2)
            Text(title)
        }
    }

    private func signedKilograms(_ value: Double?) -> String {
        guard let value else { return "— kg" }
        return "\(value.formatted(.number.sign(strategy: .always()).precision(.fractionLength(1)))) kg"
    }

    private var weightComparisonRequirementText: String {
        let completedDayCapacity = max(range.dayCount - 1, 0)
        let requiredSpanDays = min(
            WeightBalanceComparisonBuilder.minimumComparisonWeightSpanDays,
            completedDayCapacity
        )
        let requiredBalanceDays = min(
            WeightBalanceComparisonBuilder.minimumComparisonBalanceDayCount,
            completedDayCapacity
        )
        return "Im gewählten Zeitraum braucht der Vergleich mindestens vier Gewichtstage über \(requiredSpanDays) Tage und \(requiredBalanceDays) vollständige Bilanztage."
    }

    private func weightInterpretation(_ comparison: WeightBalanceComparison) -> String {
        guard let observed = comparison.observedChangeKilograms,
              let expected = comparison.expectedChangeKilograms else {
            return "Für eine Einordnung fehlen noch auswertbare Daten."
        }
        let difference = observed - expected
        if abs(difference) <= 0.5 {
            return "Der geglättete Gewichtstrend passt im gewählten Zeitraum grob zur berechneten Bilanz."
        }
        if difference < 0 {
            return "Das Gewicht sank stärker beziehungsweise stieg weniger als aus der Bilanz erwartet. Prüfe vor allem, ob Mahlzeiten regelmäßig und vollständig erfasst wurden."
        }
        return "Das Gewicht sank weniger beziehungsweise stieg stärker als aus der Bilanz erwartet. Kurzfristige Schwankungen und unvollständige Erfassung können die Abweichung erklären."
    }

    private func weightComparisonAccessibilityValue(
        _ comparison: WeightBalanceComparison
    ) -> String {
        "Beobachtete Änderung \(signedKilograms(comparison.observedChangeKilograms)), erwartete Änderung \(signedKilograms(comparison.expectedChangeKilograms))"
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

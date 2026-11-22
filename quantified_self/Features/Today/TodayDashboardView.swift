import Charts
import SwiftUI

private enum EnergyChartLegendLineStyle {
    case solid
    case dashed
    case dotted

    var segments: (count: Int, width: CGFloat, spacing: CGFloat) {
        switch self {
        case .solid: (1, 18, 0)
        case .dashed: (3, 4, 3)
        case .dotted: (4, 3, 2)
        }
    }
}

struct TodayDashboardView: View {
    let snapshot: TodayDashboardSnapshot
    let weeklySummary: WeeklyNutritionSummary?
    let intakeForecast: TodayIntakeForecast?
    let energyBalance: DailyEnergyBalance?
    let expenditureForecast: EnergyExpenditureForecast?
    let energyTrend: TodayEnergyTrend?
    let healthStatus: HealthDataStatus
    let onAddFood: () -> Void
    let onRetryMeal: (UUID) -> Void
    let onOpenMeal: (UUID) -> Void
    let onOpenSettings: () -> Void
    @State private var energyChartWidth: CGFloat = 0

    init(
        snapshot: TodayDashboardSnapshot,
        weeklySummary: WeeklyNutritionSummary? = nil,
        intakeForecast: TodayIntakeForecast? = nil,
        energyBalance: DailyEnergyBalance? = nil,
        expenditureForecast: EnergyExpenditureForecast? = nil,
        energyTrend: TodayEnergyTrend? = nil,
        healthStatus: HealthDataStatus = .notRequested,
        onAddFood: @escaping () -> Void,
        onRetryMeal: @escaping (UUID) -> Void = { _ in },
        onOpenMeal: @escaping (UUID) -> Void = { _ in },
        onOpenSettings: @escaping () -> Void = {}
    ) {
        self.snapshot = snapshot
        self.weeklySummary = weeklySummary
        self.intakeForecast = intakeForecast
        self.energyBalance = energyBalance
        self.expenditureForecast = expenditureForecast
        self.energyTrend = energyTrend
        self.healthStatus = healthStatus
        self.onAddFood = onAddFood
        self.onRetryMeal = onRetryMeal
        self.onOpenMeal = onOpenMeal
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: QuantLayout.sectionSpacing) {
                dateHeader
                calorieCard
                healthStatusCard
                hintsSection
                weeklyCalorieCard
                macroCard
                mealsSection
            }
            .padding(.horizontal, QuantLayout.pageInset)
            .padding(.bottom, 96)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Heute")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onOpenSettings) {
                    Label("Einstellungen", systemImage: "gearshape")
                }
                .accessibilityIdentifier("settings.open")
            }
        }
        .safeAreaInset(edge: .bottom) {
            addFoodButton
        }
    }

    private var dateHeader: some View {
        Text(snapshot.date.formatted(
            .dateTime
                .weekday(.wide)
                .day()
                .month(.wide)
                .locale(Locale(identifier: "de_DE"))
        ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .accessibilityLabel(snapshot.date.formatted(
                Date.FormatStyle(date: .complete, time: .omitted)
                    .locale(Locale(identifier: "de_DE"))
            ))
    }

    private var calorieCard: some View {
        energyBalanceCard(energyBalance)
    }

    private func energyBalanceCard(_ balance: DailyEnergyBalance?) -> some View {
        QuantCard(style: .hero) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Energiebilanz am Tagesende")
                    .font(.headline)

                energyForecastSummary(balance)

                if let energyTrend, energyTrend.hasChartData {
                    energyTrendChart(energyTrend)
                }

                Divider()
                energyBalanceTable(balance)

                if balance?.isCurrentDay ?? true,
                   intakeForecast == nil || expenditureForecast == nil {
                    Label("Für die Hochrechnung fehlen noch Verlaufsdaten.", systemImage: "clock.arrow.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let target = snapshot.energy.target {
                    Divider()
                    HStack {
                        Text("Aufnahmeziel")
                        Spacer()
                        Text(intakeGoalText(target: target))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(
                        value: min(snapshot.energy.consumed, target),
                        total: target
                    )
                    .tint(remainingColor)
                    .accessibilityLabel("Fortschritt zum Aufnahmeziel")
                    .accessibilityValue(progressAccessibilityValue)
                }
            }
        }
        .accessibilityIdentifier("today.energyBalance")
    }

    @ViewBuilder
    private func energyForecastSummary(_ balance: DailyEnergyBalance?) -> some View {
        if let projectedBalance {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("≈ \(wholeNumber(abs(projectedBalance))) kcal")
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .foregroundStyle(balanceColor(projectedBalance))
                    Text(balanceDirection(projectedBalance))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                if let currentBalance = balance?.balanceKilocalories {
                    Text("Jetzt: \(TodayEnergyValueFormatter.text(currentBalance, showsSign: true)) kcal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("today.balanceSummary")
        }
    }

    private func energyTrendChart(_ trend: TodayEnergyTrend) -> some View {
        let scale = TodayEnergyChartScaleBuilder.makeScale(for: trend)
        let legend = TodayEnergyChartLegendBuilder.makeLegend(for: trend)
        return VStack(alignment: .leading, spacing: 10) {
            energySeriesLegend(legend)

            Chart {
                RuleMark(y: .value("Ausgeglichen", 0))
                    .foregroundStyle(.secondary)

                ForEach(trend.intakeActualPoints) { point in
                    LineMark(
                        x: .value("Uhrzeit", point.hour),
                        y: .value("Aufnahme", point.value),
                        series: .value("Reihe", "Aufnahme bisher")
                    )
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 3))
                }
                ForEach(trend.intakeForecastPoints) { point in
                    LineMark(
                        x: .value("Uhrzeit", point.hour),
                        y: .value("Aufnahme", point.value),
                        series: .value("Reihe", "Aufnahme Prognose")
                    )
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 3, dash: [7, 5]))
                }
                ForEach(trend.expenditureActualPoints) { point in
                    LineMark(
                        x: .value("Uhrzeit", point.hour),
                        y: .value("Verbrauch", -point.value),
                        series: .value("Reihe", "Verbrauch bisher")
                    )
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(.purple)
                    .lineStyle(StrokeStyle(lineWidth: 3))
                }
                ForEach(trend.expenditureForecastPoints) { point in
                    LineMark(
                        x: .value("Uhrzeit", point.hour),
                        y: .value("Verbrauch", -point.value),
                        series: .value("Reihe", "Verbrauch Prognose")
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.purple)
                    .lineStyle(StrokeStyle(lineWidth: 3, dash: [7, 5]))
                }
                ForEach(trend.balanceActualPoints) { point in
                    LineMark(
                        x: .value("Uhrzeit", point.hour),
                        y: .value("Bilanz", point.value),
                        series: .value("Reihe", "Bilanz bisher")
                    )
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(.green)
                    .lineStyle(StrokeStyle(lineWidth: 3))
                }
                ForEach(trend.balanceForecastPoints) { point in
                    LineMark(
                        x: .value("Uhrzeit", point.hour),
                        y: .value("Bilanz", point.value),
                        series: .value("Reihe", "Bilanz Prognose")
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.green)
                    .lineStyle(StrokeStyle(lineWidth: 3, dash: [7, 5]))
                }
                ForEach(trend.averageIntakePoints) { point in
                    LineMark(
                        x: .value("Uhrzeit", point.hour),
                        y: .value("Typische Aufnahme", point.value),
                        series: .value("Reihe", "Typischer Aufnahmetag")
                    )
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [3, 5]))
                }
                if let endpoint = trend.balanceForecastPoints.last {
                    PointMark(
                        x: .value("Uhrzeit", endpoint.hour),
                        y: .value("Bilanz", endpoint.value)
                    )
                    .foregroundStyle(.green)
                    .annotation(
                        position: endpoint.value >= 0 ? .top : .bottom,
                        alignment: .trailing
                    ) {
                        Text("≈ \(TodayEnergyValueFormatter.text(endpoint.value, showsSign: true))")
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(.green)
                    }
                }
            }
            .chartXScale(domain: 0...24)
            .chartYScale(domain: scale.domain)
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
                AxisMarks(position: .leading, values: scale.axisValues) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(number.formatted(.number.precision(.fractionLength(0))))
                        }
                    }
                }
            }
            .frame(height: TodayEnergyChartLayout.height(for: energyChartWidth))
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                energyChartWidth = width
            }
            .accessibilityLabel("Tagesverlauf von Aufnahme, Verbrauch und Bilanz")
            .accessibilityValue(energyTrendAccessibilityValue(trend))
            .accessibilityIdentifier("today.energyTrendChart")

            ViewThatFits(in: .horizontal) {
                HStack {
                    energyChartLegend(title: "Bisher", color: .secondary)
                    Spacer(minLength: 8)
                    energyChartLegend(
                        title: legend.forecastTitle,
                        color: .secondary,
                        lineStyle: .dashed
                    )
                }
                VStack(alignment: .leading, spacing: 6) {
                    energyChartLegend(title: "Bisher", color: .secondary)
                    energyChartLegend(
                        title: legend.forecastTitle,
                        color: .secondary,
                        lineStyle: .dashed
                    )
                }
            }
            .font(.caption2)
        }
    }

    private func energySeriesLegend(_ legend: TodayEnergyChartLegend) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                energyChartLegend(title: "+ Aufnahme", color: .blue)
                energyChartLegend(title: "− Verbrauch", color: .purple)
                energyChartLegend(title: "= Bilanz", color: .green)
                if let typicalIntakeTitle = legend.typicalIntakeTitle {
                    energyChartLegend(
                        title: typicalIntakeTitle,
                        color: .orange,
                        lineStyle: .dotted
                    )
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) {
                    energyChartLegend(title: "+ Aufnahme", color: .blue)
                    energyChartLegend(title: "− Verbrauch", color: .purple)
                }
                HStack(spacing: 14) {
                    energyChartLegend(title: "= Bilanz", color: .green)
                    if let typicalIntakeTitle = legend.typicalIntakeTitle {
                        energyChartLegend(
                            title: typicalIntakeTitle,
                            color: .orange,
                            lineStyle: .dotted
                        )
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                energyChartLegend(title: "+ Aufnahme", color: .blue)
                energyChartLegend(title: "− Verbrauch", color: .purple)
                energyChartLegend(title: "= Bilanz", color: .green)
                if let typicalIntakeTitle = legend.typicalIntakeTitle {
                    energyChartLegend(
                        title: typicalIntakeTitle,
                        color: .orange,
                        lineStyle: .dotted
                    )
                }
            }
        }
        .font(.caption)
    }

    private func energyChartLegend(
        title: String,
        color: Color,
        lineStyle: EnergyChartLegendLineStyle = .solid
    ) -> some View {
        let segments = lineStyle.segments
        return HStack(spacing: 5) {
            HStack(spacing: segments.spacing) {
                ForEach(0..<segments.count, id: \.self) { _ in
                    Capsule()
                        .fill(color)
                        .frame(width: segments.width, height: 3)
                }
            }
            .frame(width: 18, alignment: .leading)
            Text(title)
                .foregroundStyle(color)
        }
    }

    private func energyBalanceTable(_ balance: DailyEnergyBalance?) -> some View {
        let showsForecastColumn = balance?.isCurrentDay ?? true
        return Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 9) {
            GridRow {
                Text("kcal")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .gridColumnAlignment(.leading)
                Text("Jetzt")
                if showsForecastColumn {
                    Text("Tagesende")
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            energyTableRow(
                title: "Aufnahme",
                current: balance?.intakeKilocalories,
                currentIsProvisional: snapshot.hasProvisionalValues,
                forecast: showsForecastColumn ? intakeForecast?.energyKilocalories : nil,
                forecastIdentifier: "today.intakeForecast",
                showsForecastColumn: showsForecastColumn,
                showsSign: true,
                color: .blue
            )
            energyTableRow(
                title: "Verbrauch",
                current: balance?.expenditureKilocalories.map { -$0 },
                forecast: showsForecastColumn ? expenditureForecast.map { -$0.totalKilocalories } : nil,
                forecastIdentifier: "today.expenditureForecast",
                showsForecastColumn: showsForecastColumn,
                showsSign: true,
                color: .purple
            )
            energyTableRow(
                title: "Bilanz",
                current: balance?.balanceKilocalories,
                forecast: showsForecastColumn ? projectedBalance : nil,
                forecastIdentifier: "today.balanceForecast",
                showsForecastColumn: showsForecastColumn,
                showsSign: true,
                color: .green
            )
        }
    }

    private func energyTableRow(
        title: String,
        current: Double?,
        currentIsProvisional: Bool = false,
        forecast: Double?,
        forecastIdentifier: String,
        showsForecastColumn: Bool,
        showsSign: Bool = false,
        color: Color? = nil
    ) -> some View {
        GridRow {
            Text(title)
                .fontWeight(showsSign ? .semibold : .regular)
                .frame(maxWidth: .infinity, alignment: .leading)
            energyTableValue(
                current,
                showsSign: showsSign,
                isProvisional: currentIsProvisional
            )
                .foregroundStyle(color ?? .primary)
            if showsForecastColumn {
                energyTableValue(forecast, showsSign: showsSign)
                    .foregroundStyle(color ?? .primary)
                    .accessibilityIdentifier(forecastIdentifier)
            }
        }
    }

    private func energyTableValue(
        _ value: Double?,
        showsSign: Bool,
        isProvisional: Bool = false
    ) -> some View {
        Text(TodayEnergyValueFormatter.text(
            value,
            showsSign: showsSign,
            isProvisional: isProvisional
        ))
            .fontWeight(showsSign ? .semibold : .regular)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    @ViewBuilder
    private var healthStatusCard: some View {
        switch healthStatus {
        case .notRequested:
            QuantCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Energiebilanz einrichten", systemImage: "heart.text.square")
                        .font(.headline)
                    Text("Verbinde Apple Health, damit Quant Aktivitäts- und Ruheenergie mit deiner Aufnahme verrechnet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Apple Health einrichten", action: onOpenSettings)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("today.setupHealth")
                }
            }
        case .noData:
            Label(
                "Für heute sind noch keine vollständigen Verbrauchsdaten in Apple Health verfügbar.",
                systemImage: "heart.slash"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .failed:
            Label("Apple-Health-Daten konnten nicht geladen werden.", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }

    private var macroCard: some View {
        QuantCard(style: .hero) {
            VStack(spacing: 18) {
                ForEach(snapshot.macros + [snapshot.fiber]) { progress in
                    macroRow(progress)
                }
            }
        }
    }

    private var weeklyCalorieCard: some View {
        QuantCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Aufnahme diese Woche")
                    .font(.headline)
                if snapshot.hasProvisionalWeeklyValues {
                    Text("~ Enthält vorläufige Schätzwerte aus offenen Rückfragen.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("\(snapshot.hasProvisionalWeeklyValues ? "~" : "")\(wholeNumber(snapshot.weeklyEnergy.consumed)) kcal")
                        .font(.title3.bold().monospacedDigit())
                    Spacer()
                    if let target = snapshot.weeklyEnergy.target {
                        Text("von \(wholeNumber(target)) kcal")
                            .foregroundStyle(.secondary)
                    }
                }
                if let target = snapshot.weeklyEnergy.target {
                    ProgressView(
                        value: min(snapshot.weeklyEnergy.consumed, target),
                        total: target
                    )
                    Text(weeklyRemainingText(target: target))
                        .font(.subheadline)
                        .foregroundStyle(snapshot.weeklyEnergy.consumed <= target ? .green : .orange)
                } else {
                    Text("Für diese Woche ist kein vollständiges Aufnahmeziel verfügbar.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let weeklySummary, weeklySummary.trackedDayCount > 0 {
                    Divider()
                    LabeledContent("Tagesdurchschnitt") {
                        Text("\(weeklySummary.hasProvisionalValues ? "~" : "")\(wholeNumber(weeklySummary.averageEnergyKilocalories ?? 0)) kcal")
                    }
                    LabeledContent("Makros Ø") {
                        Text("\(weeklySummary.hasProvisionalValues ? "~" : "")\(macroAverageText(weeklySummary))")
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Tage im Ziel") {
                        Text("\(weeklySummary.daysWithinEnergyTarget) von \(weeklySummary.trackedDayCount)")
                    }
                    if let change = weeklySummary.previousWeekAverageEnergyChangePercent {
                        LabeledContent("Zur Vorwoche") {
                            Text("\(weeklySummary.comparisonHasProvisionalValues ? "~" : "")\(change.formatted(.percent.scale(1).sign(strategy: .always()).precision(.fractionLength(0))))")
                        }
                    }
                }
            }
        }
    }

    private func macroAverageText(_ summary: WeeklyNutritionSummary) -> String {
        let protein = wholeNumber(summary.averageProteinGrams ?? 0)
        let carbohydrates = wholeNumber(summary.averageCarbohydratesGrams ?? 0)
        let fat = wholeNumber(summary.averageFatGrams ?? 0)
        return "P \(protein) · KH \(carbohydrates) · F \(fat) g"
    }

    private func weeklyRemainingText(target: Double) -> String {
        let remaining = target - snapshot.weeklyEnergy.consumed
        if remaining >= 0 {
            return "\(wholeNumber(remaining)) kcal verbleibend"
        }
        return "\(wholeNumber(abs(remaining))) kcal über dem Wochenziel"
    }

    private func macroRow(_ progress: NutrientProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(progress.id.dashboardTitle)
                    .font(.headline)
                Spacer()
                Text(progressText(progress))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let target = progress.target {
                ProgressView(value: min(progress.consumed, target), total: target)
                    .tint(progress.id.dashboardColor)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("today.nutrient.\(progress.id.rawValue)")
    }

    private var mealsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mahlzeiten")
                .font(.title2.bold())

            if snapshot.meals.isEmpty {
                ContentUnavailableView(
                    "Noch nichts erfasst",
                    systemImage: "fork.knife",
                    description: Text("Deine Mahlzeiten erscheinen hier, sobald du sie gespeichert hast.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(.background, in: .rect(cornerRadius: QuantLayout.heroCardCornerRadius))
            } else {
                ForEach(snapshot.meals) { meal in
                    mealRow(meal)
                }
            }
        }
    }

    @ViewBuilder
    private var hintsSection: some View {
        let hints = NutritionHintBuilder.makeHints(
            for: snapshot,
            at: snapshot.date,
            calendar: .autoupdatingCurrent
        )
        if !hints.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Hinweise")
                    .font(.headline)
                ForEach(hints) { hint in
                    Label(hint.message, systemImage: hint.systemImage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if hint.id != hints.last?.id {
                        Divider()
                    }
                }
            }
            .padding(QuantLayout.cardPadding)
            .background(.blue.opacity(0.08), in: .rect(cornerRadius: QuantLayout.cardCornerRadius))
        }
    }

    private func mealRow(_ meal: TodayMealSummary) -> some View {
        MealSummaryRow(
            id: meal.id,
            name: meal.name,
            timestamp: meal.timestamp,
            energyKilocalories: meal.energyKilocalories,
            analysisState: meal.analysisState,
            isProvisional: meal.isProvisional,
            thumbnailStorageKey: meal.thumbnailStorageKey,
            showsCardBackground: true,
            onOpen: { onOpenMeal(meal.id) },
            onRetry: { onRetryMeal(meal.id) }
        )
    }

    private var addFoodButton: some View {
        Button(action: onAddFood) {
            Label("Essen hinzufügen", systemImage: "camera.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityHint("Öffnet die Erfassung einer neuen Mahlzeit")
        .accessibilityIdentifier("today.addFood")
    }

    private var remainingColor: Color {
        guard let remaining = snapshot.energy.remaining else { return .secondary }
        return remaining >= 0 ? .green : .orange
    }

    private func intakeGoalText(target: Double) -> String {
        let estimateMarker = snapshot.hasProvisionalValues ? "~" : ""
        return "\(estimateMarker)\(wholeNumber(snapshot.energy.consumed)) / \(wholeNumber(target)) kcal"
    }

    private var progressAccessibilityValue: String {
        guard let target = snapshot.energy.target else {
            return "\(wholeNumber(snapshot.energy.consumed)) Kilokalorien"
        }
        return "\(wholeNumber(snapshot.energy.consumed)) von \(wholeNumber(target)) Kilokalorien"
    }

    private func balanceColor(_ value: Double) -> Color {
        abs(value) < 100 ? .secondary : (value < 0 ? .blue : .orange)
    }

    private var projectedBalance: Double? {
        guard let intakeForecast, let expenditureForecast else { return nil }
        return intakeForecast.energyKilocalories - expenditureForecast.totalKilocalories
    }

    private func balanceDirection(_ value: Double) -> String {
        if abs(value) < 100 { return "ausgeglichen" }
        return value < 0 ? "Defizit" : "Überschuss"
    }

    private func energyTrendAccessibilityValue(_ trend: TodayEnergyTrend) -> String {
        let currentIntake = trend.intakeActualPoints.last?.value
        let currentExpenditure = trend.expenditureActualPoints.last?.value
        let currentBalance = trend.balanceActualPoints.last?.value
        let forecastIntake = trend.intakeForecastPoints.last?.value
        let forecastExpenditure = trend.expenditureForecastPoints.last?.value
        let forecastBalance = trend.balanceForecastPoints.last?.value
        return [
            energyAccessibilityText("Aufnahme jetzt", value: currentIntake),
            energyAccessibilityText("Verbrauch jetzt", value: currentExpenditure.map { -$0 }),
            energyAccessibilityText("Bilanz jetzt", value: currentBalance),
            energyAccessibilityText("Aufnahme Tagesende", value: forecastIntake),
            energyAccessibilityText("Verbrauch Tagesende", value: forecastExpenditure.map { -$0 }),
            energyAccessibilityText("Bilanz Tagesende", value: forecastBalance),
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    private func energyAccessibilityText(_ title: String, value: Double?) -> String? {
        guard let value else { return nil }
        return "\(title) \(TodayEnergyValueFormatter.text(value, showsSign: true)) Kilokalorien"
    }

    private func progressText(_ progress: NutrientProgress) -> String {
        let consumed = wholeNumber(progress.consumed)
        if let target = progress.target {
            return "\(consumed) / \(wholeNumber(target)) \(progress.unit.rawValue)"
        }
        return "\(consumed) \(progress.unit.rawValue)"
    }

    private func wholeNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }
}

enum TodayEnergyValueFormatter {
    static func text(
        _ value: Double?,
        showsSign: Bool = false,
        isProvisional: Bool = false
    ) -> String {
        guard let value else { return "—" }
        let sign: String
        if !showsSign {
            sign = ""
        } else if value < -0.5 {
            sign = "−"
        } else if value > 0.5 {
            sign = "+"
        } else {
            sign = ""
        }
        let estimateMarker = isProvisional ? "~" : ""
        let displayedValue = showsSign ? abs(value) : value
        let formattedValue = displayedValue.formatted(.number.precision(.fractionLength(0)))
        return "\(estimateMarker)\(sign)\(formattedValue)"
    }
}

private extension NutrientIdentifier {
    var dashboardTitle: LocalizedStringKey {
        switch self {
        case .protein: "Protein"
        case .carbohydrates: "Kohlenhydrate"
        case .fat: "Fett"
        case .fiber: "Ballaststoffe"
        default: LocalizedStringKey(rawValue)
        }
    }

    var dashboardColor: Color {
        switch self {
        case .protein: .blue
        case .carbohydrates: .orange
        case .fat: .purple
        case .fiber: .green
        default: .accentColor
        }
    }
}

#if DEBUG
#Preview("Heute – Beispieldaten") {
    NavigationStack {
        TodayDashboardView(
            snapshot: .preview,
            intakeForecast: TodayIntakeForecast(
                energyKilocalories: 2_100,
                historicalDayCount: 18
            ),
            energyBalance: DailyEnergyBalance(
                date: TodayDashboardSnapshot.preview.date,
                intakeKilocalories: 1_640,
                activeKilocalories: 520,
                restingKilocalories: 1_120,
                completeness: .provisionalIntake,
                isCurrentDay: true
            ),
            expenditureForecast: EnergyExpenditureForecast(
                activeKilocalories: 720,
                restingKilocalories: 1_580,
                historicalDayCount: 42,
                method: .historicalRemainder
            ),
            energyTrend: TodayEnergyTrend(
                intakeActualPoints: [
                    .init(hour: 0, value: 0),
                    .init(hour: 8, value: 420),
                    .init(hour: 12, value: 1_180),
                    .init(hour: 18, value: 1_640),
                ],
                intakeForecastPoints: [
                    .init(hour: 18, value: 1_640),
                    .init(hour: 20, value: 1_940),
                    .init(hour: 24, value: 2_100),
                ],
                averageIntakePoints: [
                    .init(hour: 0, value: 0),
                    .init(hour: 8, value: 380),
                    .init(hour: 12, value: 1_020),
                    .init(hour: 18, value: 1_610),
                    .init(hour: 24, value: 2_080),
                ],
                expenditureActualPoints: [
                    .init(hour: 0, value: 0),
                    .init(hour: 8, value: 620),
                    .init(hour: 12, value: 1_140),
                    .init(hour: 18, value: 1_640),
                ],
                expenditureForecastPoints: [
                    .init(hour: 18, value: 1_640),
                    .init(hour: 20, value: 1_860),
                    .init(hour: 24, value: 2_300),
                ],
                balanceActualPoints: [
                    .init(hour: 0, value: 0),
                    .init(hour: 8, value: -200),
                    .init(hour: 12, value: 40),
                    .init(hour: 18, value: 0),
                ],
                balanceForecastPoints: [
                    .init(hour: 18, value: 0),
                    .init(hour: 20, value: 80),
                    .init(hour: 24, value: -200),
                ],
                intakeHistoricalDayCount: 18,
                expenditureHistoricalDayCount: 42
            ),
            healthStatus: .available,
            onAddFood: {}
        )
    }
}
#endif

import SwiftUI

struct TodayDashboardView: View {
    let snapshot: TodayDashboardSnapshot
    let weeklySummary: WeeklyNutritionSummary?
    let onAddFood: () -> Void
    let onRetryMeal: (UUID) -> Void
    let onOpenMeal: (UUID) -> Void

    init(
        snapshot: TodayDashboardSnapshot,
        weeklySummary: WeeklyNutritionSummary? = nil,
        onAddFood: @escaping () -> Void,
        onRetryMeal: @escaping (UUID) -> Void = { _ in },
        onOpenMeal: @escaping (UUID) -> Void = { _ in }
    ) {
        self.snapshot = snapshot
        self.weeklySummary = weeklySummary
        self.onAddFood = onAddFood
        self.onRetryMeal = onRetryMeal
        self.onOpenMeal = onOpenMeal
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    dateHeader
                    calorieCard
                    hintsSection
                    weeklyCalorieCard
                    macroCard
                    mealsSection
                }
                .padding(.horizontal)
                .padding(.bottom, 96)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Heute")
            .safeAreaInset(edge: .bottom) {
                addFoodButton
            }
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Kalorien")
                    .font(.headline)
                Spacer()
                if snapshot.hasProvisionalValues {
                    Text("VORLÄUFIG")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.12), in: .capsule)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(estimatedNumber(snapshot.energy.consumed))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                if let target = snapshot.energy.target {
                    Text("/ \(wholeNumber(target)) kcal")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("kcal")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if let target = snapshot.energy.target {
                ProgressView(
                    value: min(snapshot.energy.consumed, target),
                    total: target
                )
                .tint(remainingColor)
                .accessibilityLabel("Kalorienfortschritt")
                .accessibilityValue(progressAccessibilityValue)
            }

            Text(remainingEnergyText)
                .font(.headline)
                .foregroundStyle(remainingColor)
        }
        .padding(20)
        .background(.background, in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .combine)
    }

    private var macroCard: some View {
        VStack(spacing: 18) {
            ForEach(snapshot.macros + [snapshot.fiber]) { progress in
                macroRow(progress)
            }
        }
        .padding(20)
        .background(.background, in: .rect(cornerRadius: 22))
    }

    private var weeklyCalorieCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Diese Woche")
                .font(.headline)
            HStack(alignment: .firstTextBaseline) {
                Text("\(wholeNumber(snapshot.weeklyEnergy.consumed)) kcal")
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
                Text("Für diese Woche ist kein vollständiges Kalorienziel verfügbar.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let weeklySummary, weeklySummary.trackedDayCount > 0 {
                Divider()
                LabeledContent("Tagesdurchschnitt") {
                    Text("\(wholeNumber(weeklySummary.averageEnergyKilocalories ?? 0)) kcal")
                }
                LabeledContent("Makros Ø") {
                    Text(macroAverageText(weeklySummary))
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Tage im Ziel") {
                    Text("\(weeklySummary.daysWithinEnergyTarget) von \(weeklySummary.trackedDayCount)")
                }
                if let change = weeklySummary.previousWeekAverageEnergyChangePercent {
                    LabeledContent("Zur Vorwoche") {
                        Text(change.formatted(.percent.scale(1).sign(strategy: .always()).precision(.fractionLength(0))))
                    }
                }
                Text("Nur bestätigte Mahlzeiten; fehlende Tage zählen nicht als null.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.background, in: .rect(cornerRadius: 18))
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
                .background(.background, in: .rect(cornerRadius: 22))
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
            .padding(18)
            .background(.blue.opacity(0.08), in: .rect(cornerRadius: 18))
        }
    }

    private func mealRow(_ meal: TodayMealSummary) -> some View {
        HStack(spacing: 14) {
            Button {
                onOpenMeal(meal.id)
            } label: {
                HStack(spacing: 14) {
                    StoredMealThumbnailView(storageKey: meal.thumbnailStorageKey)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(mealDisplayName(meal))
                            .font(.headline)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            Text(meal.timestamp, format: .dateTime.hour().minute())
                            analysisStateLabel(meal)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    if let energy = meal.energyKilocalories {
                        Text("\(meal.isProvisional ? "~" : "")\(wholeNumber(energy)) kcal")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Öffnet die Analyse dieser Mahlzeit")
            .accessibilityIdentifier("meal.open.\(meal.id.uuidString)")

            if meal.analysisState == .failed {
                Button {
                    onRetryMeal(meal.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Analyse erneut versuchen")
                .accessibilityIdentifier("meal.retry.\(meal.id.uuidString)")
            }
        }
        .padding(14)
        .background(.background, in: .rect(cornerRadius: 18))
    }

    private func analysisStateLabel(_ meal: TodayMealSummary) -> some View {
        Group {
            if meal.analysisState != .confirmed {
                Label(meal.analysisState.dashboardTitle, systemImage: meal.analysisState.dashboardSystemImage)
                    .foregroundStyle(meal.analysisState.dashboardColor)
            }
        }
    }

    private func mealDisplayName(_ meal: TodayMealSummary) -> String {
        guard let name = meal.name, !name.isEmpty else { return "Mahlzeit" }
        return name
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

    private var remainingEnergyText: String {
        guard let remaining = snapshot.energy.remaining else {
            return "Noch kein Kalorienziel festgelegt"
        }
        if remaining >= 0 {
            return "\(wholeNumber(remaining)) kcal verbleibend"
        }
        return "\(wholeNumber(abs(remaining))) kcal über dem Ziel"
    }

    private var remainingColor: Color {
        guard let remaining = snapshot.energy.remaining else { return .secondary }
        return remaining >= 0 ? .green : .orange
    }

    private var progressAccessibilityValue: String {
        guard let target = snapshot.energy.target else {
            return "\(wholeNumber(snapshot.energy.consumed)) Kilokalorien"
        }
        return "\(wholeNumber(snapshot.energy.consumed)) von \(wholeNumber(target)) Kilokalorien"
    }

    private func progressText(_ progress: NutrientProgress) -> String {
        let consumed = wholeNumber(progress.consumed)
        if let target = progress.target {
            return "\(consumed) / \(wholeNumber(target)) \(progress.unit.rawValue)"
        }
        return "\(consumed) \(progress.unit.rawValue)"
    }

    private func estimatedNumber(_ value: Double) -> String {
        value > 0 ? "~\(wholeNumber(value))" : wholeNumber(value)
    }

    private func wholeNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
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

private extension AnalysisState {
    var dashboardTitle: LocalizedStringKey {
        switch self {
        case .pending: "Ausstehend"
        case .analyzing: "Wird analysiert"
        case .needsClarification: "Rückfrage"
        case .awaitingConfirmation: "Zu bestätigen"
        case .confirmed: "Bestätigt"
        case .failed: "Fehlgeschlagen"
        }
    }

    var dashboardSystemImage: String {
        switch self {
        case .pending: "clock"
        case .analyzing: "sparkles"
        case .needsClarification: "questionmark.circle"
        case .awaitingConfirmation: "checkmark.circle"
        case .confirmed: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var dashboardColor: Color {
        switch self {
        case .pending, .analyzing: .secondary
        case .needsClarification, .awaitingConfirmation: .orange
        case .confirmed: .green
        case .failed: .red
        }
    }
}

#if DEBUG
#Preview("Heute – Beispieldaten") {
    TodayDashboardView(snapshot: .preview, onAddFood: {})
}
#endif

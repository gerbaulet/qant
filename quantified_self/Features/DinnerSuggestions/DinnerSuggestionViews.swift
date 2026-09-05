import SwiftData
import SwiftUI

struct DinnerSuggestionFlowView: View {
    let snapshot: TodayDashboardSnapshot

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DinnerSuggestionBatch.createdAt, order: .reverse)
    private var batches: [DinnerSuggestionBatch]
    @State private var portionCount: Int
    @State private var availableIngredients: String
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var latestBatchID: UUID?

    private let preferenceStore: any DinnerPreferenceStoring
    private let provider: any DinnerSuggestionProviding

    init(
        snapshot: TodayDashboardSnapshot,
        preferenceStore: any DinnerPreferenceStoring = UserDefaultsDinnerPreferenceStore(),
        provider: any DinnerSuggestionProviding = OpenRouterDinnerSuggestionService()
    ) {
        self.snapshot = snapshot
        self.preferenceStore = preferenceStore
        self.provider = provider
        _portionCount = State(initialValue: 1)
        _availableIngredients = State(initialValue: preferenceStore.preferences.availableIngredients)
    }

    var body: some View {
        NavigationStack {
            Form {
                budgetSection

                Section("Für wie viele Personen?") {
                    Stepper("\(portionCount) \(portionCount == 1 ? "Portion" : "Portionen")", value: $portionCount, in: 1...12)
                    Text("Eine Portion wird auf dein verbleibendes Tagesbudget abgestimmt. Die Zutatenmengen gelten für alle Portionen zusammen.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Vorhandene Zutaten") {
                    TextField("Optional, z. B. Brokkoli, Reis, Tofu", text: $availableIngredients, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section {
                    Button {
                        generate()
                    } label: {
                        HStack {
                            Label(latestBatchID == nil ? "3 Vorschläge erstellen" : "Andere Vorschläge", systemImage: "sparkles")
                            Spacer()
                            if isGenerating { ProgressView() }
                        }
                    }
                    .disabled(isGenerating)
                    .accessibilityIdentifier("dinnerSuggestions.generate")

                    Text("Jede Generierung verwendet eine kostenpflichtige Modellanfrage. Alle drei Ergebnisse werden lokal gespeichert.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                if let latestBatch {
                    Section("Neueste Vorschläge") {
                        ForEach(latestBatch.suggestions.sorted(by: { $0.sortIndex < $1.sortIndex })) { suggestion in
                            NavigationLink {
                                DinnerSuggestionDetailView(suggestion: suggestion)
                            } label: {
                                suggestionLabel(suggestion)
                            }
                        }
                    }
                }

                if !batches.isEmpty {
                    Section {
                        NavigationLink("Bisherige Vorschläge") {
                            DinnerSuggestionHistoryView()
                        }
                    }
                }
            }
            .navigationTitle("Abendessen vorschlagen")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var latestBatch: DinnerSuggestionBatch? {
        guard let latestBatchID else { return nil }
        return batches.first { $0.id == latestBatchID }
    }

    private var budgetSection: some View {
        Section {
            if let energy = snapshot.energy.remaining {
                LabeledContent("Kalorien", value: remainingText(energy, unit: "kcal"))
                if energy <= 0 {
                    Text("Dein Kalorienziel ist bereits ausgeschöpft. Qant schlägt trotzdem leichte Abendessen vor.")
                        .foregroundStyle(.orange)
                }
            } else {
                Text("Kein Kalorienziel gesetzt. Qant berücksichtigt die übrigen vorhandenen Ziele.")
                    .foregroundStyle(.secondary)
            }
            ForEach(snapshot.macros + [snapshot.fiber]) { progress in
                LabeledContent(progress.id.dinnerTitle, value: progress.remaining.map {
                    remainingText($0, unit: progress.unit.rawValue)
                } ?? "Kein Ziel")
            }
            if snapshot.hasProvisionalValues {
                Label("Enthält vorläufig geschätzte Mahlzeitenwerte", systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Verbleibendes Tagesbudget")
        }
    }

    private func suggestionLabel(_ suggestion: DinnerSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(suggestion.name).font(.headline)
                if suggestion.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
            }
            if let energy = suggestion.nutrient(.energy) {
                Text("~\(number(energy.valuePerServing)) kcal pro Portion")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func generate() {
        var preferences = preferenceStore.preferences
        preferences.availableIngredients = availableIngredients
        preferenceStore.preferences = preferences
        errorMessage = nil
        isGenerating = true

        Task {
            do {
                let request = try DinnerSuggestionBuilder.makeRequest(
                    snapshot: snapshot,
                    portionCount: portionCount,
                    preferences: preferences,
                    availableIngredients: availableIngredients
                )
                let result = try await provider.suggestDinner(request)
                let batch = try SwiftDataDinnerSuggestionRepository(context: modelContext).save(
                    request: request,
                    result: result
                )
                latestBatchID = batch.id
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Die Vorschläge konnten nicht erstellt werden."
            }
            isGenerating = false
        }
    }

    private func remainingText(_ value: Double, unit: String) -> String {
        value >= 0 ? "\(number(value)) \(unit)" : "\(number(abs(value))) \(unit) darüber"
    }

    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }
}

private struct DinnerSuggestionHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DinnerSuggestionBatch.createdAt, order: .reverse)
    private var batches: [DinnerSuggestionBatch]

    var body: some View {
        List {
            if batches.isEmpty {
                ContentUnavailableView("Keine Vorschläge", systemImage: "fork.knife")
            }
            if !favoriteSuggestions.isEmpty {
                Section("Favoriten") {
                    ForEach(favoriteSuggestions) { suggestion in
                        historyRow(suggestion)
                    }
                }
            }
            if !regularSuggestions.isEmpty {
                Section("Alle Vorschläge") {
                    ForEach(regularSuggestions) { suggestion in
                        historyRow(suggestion)
                    }
                }
            }
        }
        .navigationTitle("Bisherige Vorschläge")
        .toolbar {
            Button("Nicht favorisierte löschen", role: .destructive) { deleteNonFavorites() }
                .disabled(batches.allSatisfy { $0.suggestions.allSatisfy(\.isFavorite) })
        }
    }

    private var favoriteSuggestions: [DinnerSuggestion] {
        sortedSuggestions.filter(\.isFavorite)
    }

    private var regularSuggestions: [DinnerSuggestion] {
        sortedSuggestions.filter { !$0.isFavorite }
    }

    private var sortedSuggestions: [DinnerSuggestion] {
        batches.flatMap(\.suggestions).sorted {
            let leftDate = $0.batch?.createdAt ?? .distantPast
            let rightDate = $1.batch?.createdAt ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return $0.sortIndex < $1.sortIndex
        }
    }

    private func historyRow(_ suggestion: DinnerSuggestion) -> some View {
        NavigationLink {
            DinnerSuggestionDetailView(suggestion: suggestion)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(suggestion.name)
                    Spacer()
                    if suggestion.isFavorite {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                    }
                }
                if let batch = suggestion.batch {
                    Text("\(batch.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(batch.portionCount) Portionen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .swipeActions {
            Button("Löschen", role: .destructive) {
                try? SwiftDataDinnerSuggestionRepository(context: modelContext).delete(suggestion)
            }
            Button(suggestion.isFavorite ? "Entfernen" : "Favorit") {
                suggestion.isFavorite.toggle()
                try? modelContext.save()
            }
            .tint(.yellow)
        }
    }

    private func deleteNonFavorites() {
        try? SwiftDataDinnerSuggestionRepository(context: modelContext)
            .deleteNonFavorites(in: batches)
    }
}

private struct DinnerSuggestionDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let suggestion: DinnerSuggestion

    var body: some View {
        List {
            Section {
                Text(suggestion.fitSummary)
                if suggestion.batch?.hadNoEnergyRoom == true {
                    Label("Beim Erstellen war das Kalorienziel bereits ausgeschöpft.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
            }

            Section("Zutaten für \(suggestion.batch?.portionCount ?? 1) Portionen") {
                ForEach(suggestion.ingredients.sorted(by: { $0.sortIndex < $1.sortIndex })) { ingredient in
                    LabeledContent(ingredient.name, value: ingredientText(ingredient))
                }
            }

            Section("Nährwerte pro Portion") {
                ForEach(suggestion.nutrients.sorted(by: nutrientOrder)) { nutrient in
                    LabeledContent(
                        nutrient.identifier?.dinnerTitle ?? nutrient.identifierRawValue,
                        value: "~\(number(nutrient.valuePerServing)) \(nutrient.unitRawValue)"
                    )
                }
            }

            Section {
                Text("Nährwerte sind KI-gestützte Schätzungen und können je nach Zutaten und Zubereitung abweichen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(suggestion.name)
        .toolbar {
            Button {
                suggestion.isFavorite.toggle()
                try? modelContext.save()
            } label: {
                Label(
                    suggestion.isFavorite ? "Aus Favoriten entfernen" : "Als Favorit speichern",
                    systemImage: suggestion.isFavorite ? "star.fill" : "star"
                )
            }
        }
    }

    private func ingredientText(_ ingredient: DinnerSuggestionIngredient) -> String {
        guard let amount = ingredient.amount else { return ingredient.unit }
        return "\(number(amount)) \(ingredient.unit)"
    }

    private func nutrientOrder(_ lhs: DinnerSuggestionNutrient, _ rhs: DinnerSuggestionNutrient) -> Bool {
        let order: [NutrientIdentifier] = [.energy, .protein, .carbohydrates, .fat, .fiber]
        return order.firstIndex(of: lhs.identifier ?? .energy) ?? 0 < order.firstIndex(of: rhs.identifier ?? .energy) ?? 0
    }

    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}

private extension NutrientIdentifier {
    var dinnerTitle: String {
        switch self {
        case .energy: "Kalorien"
        case .protein: "Protein"
        case .carbohydrates: "Kohlenhydrate"
        case .fat: "Fett"
        case .fiber: "Ballaststoffe"
        default: rawValue
        }
    }
}

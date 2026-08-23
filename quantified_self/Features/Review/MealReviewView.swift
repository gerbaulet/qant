import SwiftData
import SwiftUI

struct MealReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var meal: Meal

    private let analysisProvider: any NutritionAnalysisProviding
    private let imageStorage: any ImageStorageProviding

    @State private var clarificationAnswer = ""
    @State private var isWorking = false
    @State private var alertMessage: String?
    @State private var showsMoreNutrients = false

    init(
        meal: Meal,
        analysisProvider: any NutritionAnalysisProviding = OpenRouterNutritionAnalysisService(),
        imageStorage: any ImageStorageProviding = FileImageStorage()
    ) {
        self.meal = meal
        self.analysisProvider = analysisProvider
        self.imageStorage = imageStorage
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                photoStrip
                titleSection

                if let revision = meal.activeRevision {
                    nutritionSummary(revision)
                    confidenceSection(revision)
                    clarificationSection(revision)
                    componentsSection(revision)
                    additionalNutrientsSection(revision)
                    revisionFootnote(revision)
                } else {
                    unavailableState
                }
            }
            .padding()
            .padding(.bottom, 96)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Analyse prüfen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Fertig") { dismiss() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomAction
        }
        .alert("Aktion nicht möglich", isPresented: alertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "Unbekannter Fehler")
        }
    }

    @ViewBuilder
    private var photoStrip: some View {
        let images = meal.images.sorted { $0.sortIndex < $1.sortIndex }
        if !images.isEmpty {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(images) { image in
                        StoredMealThumbnailView(
                            storageKey: image.thumbnailStorageKey,
                            size: 132
                        )
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meal.activeRevision?.mealName ?? "Mahlzeit")
                .font(.largeTitle.bold())
            HStack(spacing: 10) {
                Text(
                    meal.timestamp,
                    format: .dateTime
                        .weekday()
                        .day()
                        .month()
                        .hour()
                        .minute()
                        .locale(Locale(identifier: "de_DE"))
                )
                Label(meal.analysisState.reviewTitle, systemImage: meal.analysisState.reviewSystemImage)
                    .foregroundStyle(meal.analysisState.reviewColor)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if let comment = meal.userComment {
                Label(comment, systemImage: "text.bubble")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func nutritionSummary(_ revision: MealAnalysisRevision) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Kalorien")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(nutrientText(.energy, in: revision, estimated: true))
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                }
                Spacer()
                if let weight = revision.estimatedTotalWeightGrams {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Portion")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("~\(wholeNumber(weight)) g")
                            .font(.title3.bold())
                    }
                }
            }

            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    macroTile("Protein", identifier: .protein, revision: revision)
                    macroTile("Kohlenhydrate", identifier: .carbohydrates, revision: revision)
                    macroTile("Fett", identifier: .fat, revision: revision)
                }
            }
        }
        .padding(20)
        .background(.background, in: .rect(cornerRadius: 22))
    }

    private func macroTile(
        _ title: LocalizedStringKey,
        identifier: NutrientIdentifier,
        revision: MealAnalysisRevision
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(nutrientText(identifier, in: revision, estimated: true))
                .font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func confidenceSection(_ revision: MealAnalysisRevision) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Vertrauen") {
                Label(revision.confidence.reviewTitle, systemImage: "gauge.with.dots.needle.50percent")
                    .foregroundStyle(revision.confidence.reviewColor)
            }
            if let uncertainty = revision.uncertaintySummary, !uncertainty.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Mögliche Unsicherheit")
                        .font(.subheadline.bold())
                    Text(uncertainty)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .background(.background, in: .rect(cornerRadius: 18))
    }

    @ViewBuilder
    private func clarificationSection(_ revision: MealAnalysisRevision) -> some View {
        if meal.analysisState == .needsClarification,
           let question = revision.clarificationQuestion,
           !question.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Label("Kurze Rückfrage", systemImage: "questionmark.bubble.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(question)
                    .font(.title3.weight(.semibold))
                TextField("Antwort eingeben", text: $clarificationAnswer, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isWorking || clarificationLimitReached)
                    .accessibilityIdentifier("meal.clarificationAnswer")
                if clarificationLimitReached {
                    Text("Das Rückfragelimit ist erreicht. Nutze jetzt die beste Schätzung.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .background(.orange.opacity(0.1), in: .rect(cornerRadius: 18))
        }
    }

    @ViewBuilder
    private func componentsSection(_ revision: MealAnalysisRevision) -> some View {
        let components = revision.components.sorted { $0.sortIndex < $1.sortIndex }
        if !components.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Bestandteile")
                    .font(.headline)
                ForEach(components) { component in
                    HStack {
                        Text(component.name)
                        Spacer()
                        if let weight = component.estimatedWeightGrams {
                            Text("~\(wholeNumber(weight)) g")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if component.id != components.last?.id {
                        Divider()
                    }
                }
            }
            .padding(18)
            .background(.background, in: .rect(cornerRadius: 18))
        }
    }

    private func additionalNutrientsSection(_ revision: MealAnalysisRevision) -> some View {
        DisclosureGroup("Weitere Nährwerte", isExpanded: $showsMoreNutrients) {
            VStack(spacing: 10) {
                ForEach(additionalNutrients(in: revision)) { nutrient in
                    LabeledContent(
                        nutrient.knownIdentifier?.reviewTitle ?? nutrient.identifierRawValue,
                        value: "~\(formattedValue(nutrient.value)) \(nutrient.unitRawValue)"
                    )
                }
            }
            .padding(.top, 12)
        }
        .padding(18)
        .background(.background, in: .rect(cornerRadius: 18))
    }

    private func revisionFootnote(_ revision: MealAnalysisRevision) -> some View {
        Text("Analyse \(meal.analysisRevisions.count) · \(revision.modelIdentifier) · Prompt v\(revision.promptVersion)")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var unavailableState: some View {
        ContentUnavailableView(
            meal.analysisState == .failed ? "Analyse fehlgeschlagen" : "Analyse läuft",
            systemImage: meal.analysisState == .failed ? "exclamationmark.triangle" : "sparkles",
            description: Text(
                meal.analysisState == .failed
                    ? "Die Mahlzeit und ihre Fotos sind sicher gespeichert."
                    : "Du kannst diese Ansicht schließen und die App weiterverwenden."
            )
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private var bottomAction: some View {
        if meal.analysisState == .awaitingConfirmation {
            actionBar {
                Button(action: confirm) {
                    Label("Schätzung bestätigen", systemImage: "checkmark.seal.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isWorking)
                .accessibilityIdentifier("meal.confirm")
            }
        } else if meal.analysisState == .needsClarification {
            actionBar {
                VStack(spacing: 10) {
                    Button(action: submitClarification) {
                        Label("Antwort senden", systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        isWorking ||
                            clarificationLimitReached ||
                            clarificationAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .accessibilityIdentifier("meal.submitClarification")

                    Button("Beste Schätzung verwenden", action: useBestEstimate)
                        .disabled(isWorking)
                        .accessibilityIdentifier("meal.bestEstimate")
                }
            }
        } else if meal.analysisState == .analyzing || isWorking {
            actionBar {
                HStack {
                    ProgressView()
                    Text("Analyse wird aktualisiert …")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        } else if meal.analysisState == .confirmed {
            actionBar {
                Label("Bestätigt", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func actionBar<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(.bar)
    }

    private var clarificationLimitReached: Bool {
        meal.clarificationCount >= MealAnalysisCoordinator.maximumClarificationCount
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )
    }

    private func confirm() {
        do {
            try makeCoordinator().confirm(meal)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func submitClarification() {
        isWorking = true
        Task {
            await makeCoordinator().answerClarification(clarificationAnswer, for: meal)
            clarificationAnswer = ""
            isWorking = false
        }
    }

    private func useBestEstimate() {
        isWorking = true
        Task {
            await makeCoordinator().useBestEstimate(for: meal)
            isWorking = false
        }
    }

    private func makeCoordinator() -> MealAnalysisCoordinator {
        MealAnalysisCoordinator(
            context: modelContext,
            provider: analysisProvider,
            imageStorage: imageStorage
        )
    }

    private func nutrientText(
        _ identifier: NutrientIdentifier,
        in revision: MealAnalysisRevision,
        estimated: Bool
    ) -> String {
        guard let nutrient = revision.nutrients.first(where: {
            $0.identifierRawValue == identifier.rawValue
        }) else { return "–" }
        return "\(estimated ? "~" : "")\(formattedValue(nutrient.value)) \(nutrient.unitRawValue)"
    }

    private func additionalNutrients(in revision: MealAnalysisRevision) -> [NutrientValue] {
        let primary: Set<NutrientIdentifier> = [.energy, .protein, .carbohydrates, .fat]
        return revision.nutrients
            .filter { nutrient in
                guard let identifier = nutrient.knownIdentifier else { return true }
                return !primary.contains(identifier)
            }
            .sorted { $0.identifierRawValue < $1.identifierRawValue }
    }

    private func wholeNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }

    private func formattedValue(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0)))
    }
}

private extension AnalysisState {
    var reviewTitle: LocalizedStringKey {
        switch self {
        case .pending: "Ausstehend"
        case .analyzing: "Wird analysiert"
        case .needsClarification: "Rückfrage"
        case .awaitingConfirmation: "Zu bestätigen"
        case .confirmed: "Bestätigt"
        case .failed: "Fehlgeschlagen"
        }
    }

    var reviewSystemImage: String {
        switch self {
        case .pending: "clock"
        case .analyzing: "sparkles"
        case .needsClarification: "questionmark.circle.fill"
        case .awaitingConfirmation: "checkmark.circle"
        case .confirmed: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var reviewColor: Color {
        switch self {
        case .pending, .analyzing: .secondary
        case .needsClarification, .awaitingConfirmation: .orange
        case .confirmed: .green
        case .failed: .red
        }
    }
}

private extension EstimateConfidence {
    var reviewTitle: LocalizedStringKey {
        switch self {
        case .low: "Niedrig"
        case .medium: "Mittel"
        case .high: "Hoch"
        }
    }

    var reviewColor: Color {
        switch self {
        case .low: .orange
        case .medium: .blue
        case .high: .green
        }
    }
}

private extension NutrientIdentifier {
    var reviewTitle: String {
        switch self {
        case .energy: "Kalorien"
        case .protein: "Protein"
        case .carbohydrates: "Kohlenhydrate"
        case .fat: "Fett"
        case .fiber: "Ballaststoffe"
        case .sugar: "Zucker"
        case .saturatedFat: "Gesättigte Fettsäuren"
        case .sodium: "Natrium"
        case .salt: "Salz"
        default: rawValue
        }
    }
}

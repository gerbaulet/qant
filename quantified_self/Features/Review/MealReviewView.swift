import SwiftData
import SwiftUI

struct MealReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var meal: Meal

    private let analysisProvider: any NutritionAnalysisProviding
    private let imageStorage: any ImageStorageProviding
    private let onDelete: (() -> Void)?

    @State private var clarificationAnswer = ""
    @State private var correctionText = ""
    @State private var isWorking = false
    @State private var alertMessage: String?
    @State private var showsMoreNutrients = false
    @State private var showsCorrectionEntry = false
    @State private var showsDeleteConfirmation = false
#if DEBUG
    @State private var hasTriggeredUITestQuickCapture = false
#endif

    init(
        meal: Meal,
        analysisProvider: any NutritionAnalysisProviding = OpenRouterNutritionAnalysisService(),
        imageStorage: any ImageStorageProviding = FileImageStorage(),
        onDelete: (() -> Void)? = nil
    ) {
        self.meal = meal
        self.analysisProvider = analysisProvider
        self.imageStorage = imageStorage
        self.onDelete = onDelete
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                photoStrip
                titleSection
                failureSection

                if let revision = meal.activeRevision {
                    nutritionSummary(revision)
                    confidenceSection(revision)
                    clarificationSection(revision)
                    componentsSection(revision)
                    additionalNutrientsSection(revision)
                    revisionHistorySection
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
            if let onDelete {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Löschen", systemImage: "trash", role: .destructive) {
                        showsDeleteConfirmation = true
                    }
                    .disabled(isWorking)
                    .accessibilityIdentifier("meal.delete")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Fertig") { dismiss() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomAction
        }
        .sheet(isPresented: $showsCorrectionEntry) {
            correctionEntry
        }
        .confirmationDialog(
            "Mahlzeit löschen?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Mahlzeit löschen", role: .destructive) {
                onDelete?()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Mahlzeit, ihre Analyse und ihre Fotos werden dauerhaft gelöscht.")
        }
        .alert("Aktion nicht möglich", isPresented: alertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "Unbekannter Fehler")
        }
        .task {
#if DEBUG
            guard
                ProcessInfo.processInfo.arguments.contains("--ui-testing-quick-capture-from-review"),
                !hasTriggeredUITestQuickCapture
            else { return }
            hasTriggeredUITestQuickCapture = true
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            QuickCaptureRequestStore().requestCapture()
#endif
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
                }
                GridRow {
                    macroTile("Fett", identifier: .fat, revision: revision)
                    macroTile("Ballaststoffe", identifier: .fiber, revision: revision)
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
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("meal.nutrient.\(identifier.rawValue)")
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

    @ViewBuilder
    private var revisionHistorySection: some View {
        if meal.analysisRevisions.count > 1 || sortedRevisions.contains(where: hasInitialRunSummaries) {
            DisclosureGroup("Analyseverlauf") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sortedRevisions) { revision in
                        revisionHistoryRow(revision)
                        if revision.id != sortedRevisions.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.top, 10)
            }
            .padding(18)
            .background(.background, in: .rect(cornerRadius: 18))
        }
    }

    private func revisionHistoryRow(_ revision: MealAnalysisRevision) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(revision.trigger.reviewTitle, systemImage: revision.trigger.reviewSystemImage)
                    .font(.subheadline.bold())
                Spacer()
                if revision.id == meal.activeRevisionID {
                    Text("AKTIV")
                        .font(.caption2.bold())
                        .foregroundStyle(.tint)
                }
            }
            HStack {
                Text(revision.createdAt, format: .dateTime.day().month().hour().minute())
                Spacer()
                Text(nutrientText(.energy, in: revision, estimated: true))
                    .font(.subheadline.monospacedDigit())
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let correction = revision.userCorrection, !correction.isEmpty {
                Text("„\(correction)“")
                    .font(.footnote)
            } else if let answer = revision.clarificationAnswer, !answer.isEmpty {
                Text("Antwort: „\(answer)“")
                    .font(.footnote)
            }

            if let question = revision.clarificationQuestion, !question.isEmpty {
                Text("Rückfrage: „\(question)“")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let failureMessage = revision.failureMessage, !failureMessage.isEmpty {
                Text("Fehler: \(failureMessage)")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            let runs = InitialAnalysisRunMetadata.decode(revision.providerMetadata)
            if !runs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Einzelne Modelläufe")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(runs) { run in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("Lauf \(run.runNumber)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(run.modelIdentifier)
                                    .font(.caption)
                                    .lineLimit(2)
                                if let provider = run.providerIdentifier, !provider.isEmpty {
                                    Text(provider)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer(minLength: 8)
                            Text("~\(wholeNumber(run.energyKilocalories)) kcal")
                                .font(.caption.bold().monospacedDigit())
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 10)
    }

    private var sortedRevisions: [MealAnalysisRevision] {
        meal.analysisRevisions.sorted { $0.createdAt > $1.createdAt }
    }

    @ViewBuilder
    private var failureSection: some View {
        if meal.analysisState == .failed,
           let failure = sortedRevisions.first(where: { $0.status == .failed }),
           let message = failure.failureMessage,
           !message.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Grund des Fehlers", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)
                Text("Diese Meldung kannst du für die Fehlersuche kopieren.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.background, in: .rect(cornerRadius: 18))
            .accessibilityIdentifier("meal.analysisFailureReason")
        }
    }

    private func hasInitialRunSummaries(_ revision: MealAnalysisRevision) -> Bool {
        !InitialAnalysisRunMetadata.decode(revision.providerMetadata).isEmpty
    }

    private var unavailableState: some View {
        ContentUnavailableView(
            meal.analysisState == .failed ? "Analyse fehlgeschlagen" : "Analyse läuft",
            systemImage: meal.analysisState == .failed ? "exclamationmark.triangle" : "sparkles",
            description: Text(
                meal.analysisState == .failed
                    ? "Die Mahlzeit und ihre Fotos sind sicher gespeichert."
                    : meal.analysisRevisions.isEmpty
                        ? "Drei unabhängige Schätzungen werden verglichen. Du kannst diese Ansicht schließen und die App weiterverwenden."
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
                VStack(spacing: 10) {
                    Button(action: confirm) {
                        Label("Schätzung bestätigen", systemImage: "checkmark.seal.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isWorking)
                    .accessibilityIdentifier("meal.confirm")

                    Button(action: { showsCorrectionEntry = true }) {
                        Label("Schätzung korrigieren", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isWorking)
                    .accessibilityIdentifier("meal.correct")
                }
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
                VStack(spacing: 10) {
                    Label("Bestätigt", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity)
                    Button(action: { showsCorrectionEntry = true }) {
                        Label("Nachträglich korrigieren", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isWorking)
                    .accessibilityIdentifier("meal.correct")
                }
            }
        } else if meal.analysisState == .failed {
            actionBar {
                Button(action: retryAnalysis) {
                    Label("Analyse erneut versuchen", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isWorking)
                .accessibilityIdentifier("meal.retryAnalysis")
            }
        }
    }

    private var correctionEntry: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $correctionText)
                        .frame(minHeight: 120)
                        .accessibilityIdentifier("meal.correctionText")
                } header: {
                    Text("Was stimmt nicht?")
                } footer: {
                    Text("Beschreibe die Korrektur frei, zum Beispiel: „Es waren nur etwa 100 g Reis.“ Die KI erstellt daraus eine vollständige neue Schätzung; die vorherige Analyse bleibt erhalten.")
                }
            }
            .navigationTitle("Schätzung korrigieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { showsCorrectionEntry = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Neu analysieren", action: submitCorrection)
                        .disabled(correctionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("meal.submitCorrection")
                }
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

    private func submitCorrection() {
        let correction = correctionText
        showsCorrectionEntry = false
        isWorking = true
        Task {
            await makeCoordinator().correct(correction, for: meal)
            correctionText = ""
            isWorking = false
        }
    }

    private func retryAnalysis() {
        isWorking = true
        Task {
            await makeCoordinator().analyze(meal)
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
        let primary: Set<NutrientIdentifier> = [.energy, .protein, .carbohydrates, .fat, .fiber]
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

private extension AnalysisTrigger {
    var reviewTitle: LocalizedStringKey {
        switch self {
        case .initial: "Erste Analyse"
        case .retry: "Erneuter Versuch"
        case .clarification: "Nach Rückfrage"
        case .correction: "Nach Korrektur"
        case .bestEstimate: "Beste Schätzung"
        }
    }

    var reviewSystemImage: String {
        switch self {
        case .initial: "sparkles"
        case .retry: "arrow.clockwise"
        case .clarification: "questionmark.bubble"
        case .correction: "pencil"
        case .bestEstimate: "wand.and.stars"
        }
    }
}

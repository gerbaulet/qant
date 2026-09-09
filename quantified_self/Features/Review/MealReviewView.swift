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
    @State private var descriptionText = ""
    @State private var isWorking = false
    @State private var alertMessage: String?
    @State private var showsMoreNutrients = false
    @State private var showsCorrectionEntry = false
    @State private var showsDeleteConfirmation = false
    @State private var showsTimestampEditor = false
    @State private var editedTimestamp: Date
    @State private var portionMultiplierDraft: Double?
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
        _editedTimestamp = State(initialValue: meal.timestamp)
        _portionMultiplierDraft = State(initialValue: meal.activeRevision?.normalizedPortionMultiplier)
    }

    var body: some View {
        let portionMultipliers = PortionMultiplierSnapshot()
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
                    revisionHistorySection(portionMultipliers: portionMultipliers)
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
        .sheet(isPresented: $showsTimestampEditor) {
            timestampEditor
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
        .onChange(of: meal.activeRevisionID) {
            portionMultiplierDraft = meal.activeRevision?.normalizedPortionMultiplier
        }
        .onDisappear {
            guard let revision = meal.activeRevision else { return }
            persistPortionMultiplier(for: revision)
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
                Button {
                    editedTimestamp = meal.timestamp
                    showsTimestampEditor = true
                } label: {
                    Label {
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
                    } icon: {
                        Image(systemName: "pencil")
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zeitpunkt ändern")
                .accessibilityIdentifier("meal.editTimestamp")
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
        let multiplier = displayedPortionMultiplier(for: revision)
        return VStack(alignment: .leading, spacing: 16) {
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
                        Text("~\(wholeNumber(weight * multiplier)) g")
                            .font(.title3.bold())
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Menge anpassen")
                        .font(.subheadline)
                    Spacer()
                    Text("\(formattedMultiplier(multiplier))×")
                        .font(.subheadline.monospacedDigit().bold())
                }
                Slider(
                    value: portionMultiplierBinding(for: revision),
                    in: 0...4,
                    step: 0.1
                ) {
                    Text("Portionenmultiplikator")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("4")
                } onEditingChanged: { isEditing in
                    if !isEditing {
                        persistPortionMultiplier(for: revision)
                    }
                }
                .accessibilityIdentifier("meal.portionMultiplier")
                .accessibilityValue("\(formattedMultiplier(multiplier))-fach")
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
        let multiplier = displayedPortionMultiplier(for: revision)
        return VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(nutrientText(identifier, in: revision, multiplier: multiplier, estimated: true))
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
        let multiplier = displayedPortionMultiplier(for: revision)
        if !components.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Bestandteile")
                    .font(.headline)
                ForEach(components) { component in
                    HStack {
                        Text(component.name)
                        Spacer()
                        if let weight = component.estimatedWeightGrams {
                            Text("~\(wholeNumber(weight * multiplier)) g")
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
        let multiplier = displayedPortionMultiplier(for: revision)
        return DisclosureGroup("Weitere Nährwerte", isExpanded: $showsMoreNutrients) {
            VStack(spacing: 10) {
                ForEach(additionalNutrients(in: revision)) { nutrient in
                    LabeledContent(
                        nutrient.knownIdentifier?.reviewTitle ?? nutrient.identifierRawValue,
                        value: "~\(formattedValue(nutrient.value * multiplier)) \(nutrient.unitRawValue)"
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
    private func revisionHistorySection(
        portionMultipliers: PortionMultiplierSnapshot
    ) -> some View {
        if meal.analysisRevisions.count > 1 || sortedRevisions.contains(where: hasInitialRunSummaries) {
            DisclosureGroup("Analyseverlauf") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sortedRevisions) { revision in
                        revisionHistoryRow(revision, portionMultipliers: portionMultipliers)
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

    private func revisionHistoryRow(
        _ revision: MealAnalysisRevision,
        portionMultipliers: PortionMultiplierSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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

            if let correction = revision.userCorrection, !correction.isEmpty {
                Text("Korrektur: „\(correction)“")
                    .font(.footnote)
            }

            let calls = InitialAnalysisRunMetadata.decodeCalls(revision.providerMetadata)
            let legacyRuns = calls.isEmpty
                ? InitialAnalysisRunMetadata.decode(revision.providerMetadata)
                : []
            if !calls.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(calls) { call in
                        analysisRunRow(
                            title: "Aufruf \(call.callNumber)",
                            subtitle: call.sampleNumber.map {
                                "Schätzung \($0) · Versuch \(call.attemptNumber)"
                            } ?? "Versuch \(call.attemptNumber)",
                            status: call.status,
                            modelIdentifier: call.modelIdentifier,
                            providerIdentifier: call.providerIdentifier,
                            requestedAt: call.requestedAt ?? revision.requestDate,
                            clarificationQuestion: call.clarificationQuestion,
                            clarificationAnswer: call.clarificationAnswer,
                            energyKilocalories: call.energyKilocalories,
                            inputTokens: call.inputTokens,
                            outputTokens: call.outputTokens,
                            costUSD: call.costUSD,
                            errorMessage: call.errorMessage
                        )
                    }
                }
                .padding(.top, 4)
            } else if !legacyRuns.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(legacyRuns) { run in
                        analysisRunRow(
                            title: "Aufruf \(run.runNumber)",
                            subtitle: "Schätzung \(run.runNumber)",
                            status: .succeeded,
                            modelIdentifier: run.modelIdentifier,
                            providerIdentifier: run.providerIdentifier,
                            requestedAt: revision.requestDate,
                            clarificationQuestion: revision.clarificationQuestion,
                            clarificationAnswer: revision.clarificationAnswer,
                            energyKilocalories: run.energyKilocalories
                        )
                    }
                }
                .padding(.top, 4)
            } else {
                analysisRunRow(
                    title: "Aufruf 1",
                    subtitle: "Übernommener Verlaufseintrag",
                    status: revision.status == .failed ? .failed : .succeeded,
                    modelIdentifier: revision.modelIdentifier,
                    providerIdentifier: revision.providerIdentifier,
                    requestedAt: revision.requestDate,
                    clarificationQuestion: revision.clarificationQuestion,
                    clarificationAnswer: revision.clarificationAnswer,
                    energyKilocalories: energyKilocalories(
                        in: revision,
                        portionMultipliers: portionMultipliers
                    ),
                    errorMessage: revision.failureMessage
                )
            }
        }
        .padding(.vertical, 10)
    }

    private func analysisRunRow(
        title: String,
        subtitle: String,
        status: AnalysisCallStatus,
        modelIdentifier: String?,
        providerIdentifier: String?,
        requestedAt: Date,
        clarificationQuestion: String?,
        clarificationAnswer: String?,
        energyKilocalories: Double?,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        costUSD: Double? = nil,
        errorMessage: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(title, systemImage: status == .succeeded
                    ? "checkmark.circle.fill"
                    : "exclamationmark.triangle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(status == .succeeded ? Color.green : Color.orange)
                Spacer()
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Modell", value: modelAndProvider(modelIdentifier, providerIdentifier))
            LabeledContent("Zeitpunkt") {
                Text(requestedAt, format: .dateTime.day().month().year().hour().minute().second())
            }
            LabeledContent("Rückfrage", value: nonempty(clarificationQuestion) ?? "—")
            LabeledContent("Antwort", value: nonempty(clarificationAnswer) ?? "—")
            LabeledContent("Kalorien", value: energyKilocalories.map { "~\(wholeNumber($0)) kcal" } ?? "—")
            if inputTokens != nil || outputTokens != nil || costUSD != nil {
                LabeledContent("Tokens") {
                    Text("Input \(inputTokens?.formatted() ?? "—") · Output \(outputTokens?.formatted() ?? "—")")
                }
                LabeledContent("Kosten", value: costUSD.map(formattedCost) ?? "—")
            }
            if let errorMessage = nonempty(errorMessage) {
                Text("Fehler: \(errorMessage)")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 10))
    }

    private func modelAndProvider(_ model: String?, _ provider: String?) -> String {
        let model = nonempty(model) ?? "—"
        guard let provider = nonempty(provider) else { return model }
        return "\(model) · \(provider)"
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func formattedCost(_ cost: Double) -> String {
        cost.formatted(.number.precision(.fractionLength(0...6))) + " USD"
    }

    private func energyKilocalories(
        in revision: MealAnalysisRevision,
        portionMultipliers: PortionMultiplierSnapshot
    ) -> Double? {
        revision.nutrients.first {
            $0.knownIdentifier == .energy && $0.knownUnit == .kilocalorie
        }.map { portionMultipliers.scaled($0.value, for: revision) }
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
        !InitialAnalysisRunMetadata.decodeCalls(revision.providerMetadata).isEmpty ||
            !InitialAnalysisRunMetadata.decode(revision.providerMetadata).isEmpty
    }

    private var unavailableState: some View {
        ContentUnavailableView(
            unavailableTitle,
            systemImage: unavailableSystemImage,
            description: Text(
                meal.analysisState == .awaitingDescription
                    ? "Ergänze eine Beschreibung, damit die gespeicherte Schnellaufnahme analysiert werden kann."
                    : meal.analysisState == .failed
                    ? "Die Mahlzeit und ihre Fotos sind sicher gespeichert."
                    : meal.analysisRevisions.isEmpty
                        ? "Drei unabhängige Schätzungen werden verglichen. Du kannst diese Ansicht schließen und die App weiterverwenden."
                        : "Du kannst diese Ansicht schließen und die App weiterverwenden."
            )
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var unavailableTitle: LocalizedStringKey {
        switch meal.analysisState {
        case .awaitingDescription: "Beschreibung ergänzen"
        case .failed: "Analyse fehlgeschlagen"
        default: "Analyse läuft"
        }
    }

    private var unavailableSystemImage: String {
        switch meal.analysisState {
        case .awaitingDescription: "text.bubble"
        case .failed: "exclamationmark.triangle"
        default: "sparkles"
        }
    }

    @ViewBuilder
    private var bottomAction: some View {
        if meal.analysisState == .awaitingDescription {
            actionBar {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Mahlzeit beschreiben", text: $descriptionText, axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isWorking)
                        .accessibilityIdentifier("meal.description")
                    Button(action: saveDescriptionAndAnalyze) {
                        Label("Beschreibung speichern und analysieren", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isWorking || descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("meal.submitDescription")
                }
            }
        } else if meal.analysisState == .awaitingConfirmation {
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

                    Button("Beste Schätzung übernehmen", action: useBestEstimate)
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

    private var timestampEditor: some View {
        NavigationStack {
            Form {
                DatePicker(
                    "Zeitpunkt",
                    selection: $editedTimestamp,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)
                .accessibilityIdentifier("meal.timestampEditor")
            }
            .navigationTitle("Zeitpunkt ändern")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { showsTimestampEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern", action: saveTimestamp)
                        .accessibilityIdentifier("meal.saveTimestamp")
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

    private func saveTimestamp() {
        do {
            try SwiftDataMealRepository(context: modelContext).updateTimestamp(
                editedTimestamp,
                for: meal
            )
            showsTimestampEditor = false
        } catch {
            alertMessage = "Der Zeitpunkt konnte nicht gespeichert werden."
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
        do {
            try makeCoordinator().useBestEstimate(for: meal)
        } catch {
            alertMessage = error.localizedDescription
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

    private func saveDescriptionAndAnalyze() {
        isWorking = true
        do {
            try SwiftDataMealRepository(context: modelContext).addDescription(descriptionText, to: meal)
            descriptionText = ""
            Task {
                await makeCoordinator().analyze(meal)
                isWorking = false
            }
        } catch {
            isWorking = false
            alertMessage = "Die Beschreibung konnte nicht gespeichert werden."
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
        multiplier: Double? = nil,
        estimated: Bool
    ) -> String {
        guard let nutrient = revision.nutrients.first(where: {
            $0.identifierRawValue == identifier.rawValue
        }) else { return "–" }
        let multiplier = multiplier ?? displayedPortionMultiplier(for: revision)
        return "\(estimated ? "~" : "")\(formattedValue(nutrient.value * multiplier)) \(nutrient.unitRawValue)"
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

    private func formattedMultiplier(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    private func portionMultiplierBinding(for revision: MealAnalysisRevision) -> Binding<Double> {
        Binding(
            get: { displayedPortionMultiplier(for: revision) },
            set: { newValue in
                portionMultiplierDraft = normalizedPortionMultiplier(newValue)
            }
        )
    }

    private func displayedPortionMultiplier(for revision: MealAnalysisRevision) -> Double {
        portionMultiplierDraft ?? revision.normalizedPortionMultiplier
    }

    private func normalizedPortionMultiplier(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max((value * 10).rounded() / 10, 0), 4)
    }

    private func persistPortionMultiplier(for revision: MealAnalysisRevision) {
        guard let portionMultiplierDraft else { return }
        let normalized = normalizedPortionMultiplier(portionMultiplierDraft)
        guard revision.normalizedPortionMultiplier != normalized else { return }

        revision.portionMultiplier = normalized
        meal.modifiedAt = .now
        do {
            try modelContext.save()
        } catch {
            alertMessage = "Die angepasste Menge konnte nicht gespeichert werden."
        }
    }
}

private extension AnalysisState {
    var reviewTitle: LocalizedStringKey {
        switch self {
        case .awaitingDescription: "Beschreibung fehlt"
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
        case .awaitingDescription: "text.bubble.fill"
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
        case .awaitingDescription: .orange
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

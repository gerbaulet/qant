import Observation
import SwiftData
import SwiftUI

struct MealReviewView: View {
    private enum FocusedField: Hashable {
        case clarification
        case description
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var meal: Meal

    private let analysisProvider: any NutritionAnalysisProviding
    private let imageStorage: any ImageStorageProviding
    private let onDelete: ((Meal) -> Void)?
    private let onDuplicate: (@MainActor (Meal) async throws -> Void)?

    @State private var clarificationAnswer = ""
    @State private var correctionText = ""
    @State private var descriptionText = ""
    @State private var isWorking = false
    @State private var alertMessage: String?
    @State private var showsMoreNutrients = false
    @State private var showsCorrectionEntry = false
    @State private var showsDeleteConfirmation = false
    @State private var showsTimestampEditor = false
    @State private var selectedPhoto: MealImage?
    @State private var successMessage: String?
    @State private var editedTimestamp: Date
    @State private var portionAdjustment: PortionAdjustmentDraft
    @State private var isMealScrollAtTop = true
    @State private var mealDismissDragStartedAtTop: Bool?
    @FocusState private var focusedField: FocusedField?
#if DEBUG
    @State private var hasTriggeredUITestQuickCapture = false
#endif

    init(
        meal: Meal,
        analysisProvider: any NutritionAnalysisProviding = OpenRouterNutritionAnalysisService(),
        imageStorage: any ImageStorageProviding = FileImageStorage(),
        showsDuplicateConfirmation: Bool = false,
        onDelete: ((Meal) -> Void)? = nil,
        onDuplicate: (@MainActor (Meal) async throws -> Void)? = nil
    ) {
        self.meal = meal
        self.analysisProvider = analysisProvider
        self.imageStorage = imageStorage
        self.onDelete = onDelete
        self.onDuplicate = onDuplicate
        _editedTimestamp = State(initialValue: meal.timestamp)
        _successMessage = State(initialValue: showsDuplicateConfirmation ? "Mahlzeit dupliziert" : nil)
        _portionAdjustment = State(initialValue: PortionAdjustmentDraft(
            multiplier: meal.activeRevision?.normalizedPortionMultiplier ?? 1,
            componentMultipliers: InitialAnalysisRunMetadata.componentMultipliers(from: meal.activeRevision?.providerMetadata)
        ))
    }

    var body: some View {
        let portionMultipliers = PortionMultiplierSnapshot()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: QuantLayout.sectionSpacing) {
                photoStrip
                titleSection

                if let revision = meal.activeRevision {
                    PortionNutritionSummary(
                        revision: revision,
                        adjustment: portionAdjustment,
                        onCommit: { persistPortionMultiplier(for: revision) }
                    )
                }

                failureSection
                liveAnalysisSection

                if let revision = meal.activeRevision {
                    confidenceSection(revision)
                    clarificationSection(revision)
                    correctionAction
                    PortionComponentsSection(
                        revision: revision,
                        adjustment: portionAdjustment,
                        onCommit: { persistPortionMultiplier(for: revision) }
                    )
                    PortionAdditionalNutrientsSection(
                        revision: revision,
                        adjustment: portionAdjustment,
                        isExpanded: $showsMoreNutrients
                    )
                    revisionHistorySection(portionMultipliers: portionMultipliers)
                    revisionFootnote(revision)
                } else {
                    unavailableState
                }
            }
            .padding(.horizontal, QuantLayout.pageInset)
            .padding(.bottom, QuantLayout.sectionSpacing)
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("meal.reviewScroll")
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y <= -geometry.contentInsets.top + 1
        } action: { _, isAtTop in
            isMealScrollAtTop = isAtTop
        }
        .simultaneousGesture(mealDismissGesture)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Mahlzeit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if onDelete != nil || (meal.canBeDuplicated && onDuplicate != nil) {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if meal.canBeDuplicated, onDuplicate != nil {
                            Button("Duplizieren", systemImage: "plus.square.on.square") {
                                duplicateMeal()
                            }
                            .accessibilityIdentifier("meal.duplicate")
                        }
                        if onDelete != nil {
                            Button("Löschen", systemImage: "trash", role: .destructive) {
                                showsDeleteConfirmation = true
                            }
                            .accessibilityIdentifier("meal.delete")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(isWorking)
                    .accessibilityLabel("Weitere Aktionen")
                    .accessibilityIdentifier("meal.actions")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomAction
        }
        .overlay(alignment: .top) {
            if let successMessage {
                Label(successMessage, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.green, in: .capsule)
                    .padding(.top, 8)
                    .accessibilityIdentifier("meal.duplicateSuccess")
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showsCorrectionEntry) {
            correctionEntry
        }
        .sheet(isPresented: $showsTimestampEditor) {
            timestampEditor
        }
        .fullScreenCover(item: $selectedPhoto) { image in
            MealPhotoViewer(
                storageKey: image.imageStorageKey,
                imageStorage: imageStorage
            )
        }
        .confirmationDialog(
            "Mahlzeit löschen?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Mahlzeit löschen", role: .destructive) {
                onDelete?(meal)
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
            portionAdjustment.multiplier = meal.activeRevision?.normalizedPortionMultiplier ?? 1
            portionAdjustment.componentMultipliers = InitialAnalysisRunMetadata.componentMultipliers(from: meal.activeRevision?.providerMetadata)
        }
        .onDisappear {
            guard let revision = meal.activeRevision else { return }
            persistPortionMultiplier(for: revision)
        }
        .task(id: successMessage) {
            guard successMessage != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            withAnimation {
                successMessage = nil
            }
        }
    }

    private var mealDismissGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { _ in
                if mealDismissDragStartedAtTop == nil {
                    mealDismissDragStartedAtTop = isMealScrollAtTop
                }
            }
            .onEnded { value in
                let startedAtTop = mealDismissDragStartedAtTop ?? isMealScrollAtTop
                mealDismissDragStartedAtTop = nil
                guard DownwardDismissGesturePolicy.shouldDismiss(
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation,
                    isEnabled: startedAtTop
                ) else { return }
                dismiss()
            }
    }

    @ViewBuilder
    private var photoStrip: some View {
        let images = meal.images.sorted { $0.sortIndex < $1.sortIndex }
        if !images.isEmpty {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                        Button {
                            selectedPhoto = image
                        } label: {
                            StoredMealThumbnailView(
                                storageKey: image.thumbnailStorageKey,
                                size: 132
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Foto \(index + 1) vergrößern")
                        .accessibilityHint("Öffnet eine Ansicht zum Zoomen")
                        .accessibilityIdentifier("meal.photo.\(image.id.uuidString)")
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
                .accessibilityIdentifier("meal.title")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    timestampButton
                    Spacer(minLength: 4)
                    MealStatusBadge(state: meal.analysisState)
                }
                VStack(alignment: .leading, spacing: 8) {
                    timestampButton
                    MealStatusBadge(state: meal.analysisState)
                }
            }

            if let comment = meal.userComment {
                Label(comment, systemImage: "text.bubble")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var timestampButton: some View {
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
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Zeitpunkt ändern")
        .accessibilityIdentifier("meal.editTimestamp")
    }

    @ViewBuilder
    private func confidenceSection(_ revision: MealAnalysisRevision) -> some View {
        if revision.confidence != .high || nonempty(revision.uncertaintySummary) != nil {
            QuantCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Schätzsicherheit", systemImage: "gauge.with.dots.needle.50percent")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(revision.confidence.reviewTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(revision.confidence.reviewColor)
                    }
                    if let uncertainty = nonempty(revision.uncertaintySummary) {
                        Text(uncertainty)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
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
                if clarificationLimitReached {
                    Text("Das Rückfragelimit ist erreicht. Nutze jetzt die beste Schätzung.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(QuantLayout.cardPadding)
            .background(
                .orange.opacity(0.1),
                in: .rect(cornerRadius: QuantLayout.cardCornerRadius)
            )
        }
    }

    @ViewBuilder
    private var correctionAction: some View {
        if meal.analysisState == .confirmed || meal.analysisState == .awaitingConfirmation {
            Button(action: { showsCorrectionEntry = true }) {
                Label("Nachträglich korrigieren", systemImage: "pencil")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isWorking)
            .accessibilityIdentifier("meal.correct")
        }
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
            .padding(QuantLayout.cardPadding)
            .background(
                .background,
                in: .rect(cornerRadius: QuantLayout.cardCornerRadius)
            )
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

    @ViewBuilder
    private var liveAnalysisSection: some View {
        if meal.analysisState == .analyzing {
            let progress = MealAnalysisProgressStore.shared.analyses[meal.id] ?? MealAnalysisProgress()
            VStack(alignment: .leading, spacing: 12) {
                Label("Laufende Analyse", systemImage: "sparkles")
                    .font(.headline)
                Text(progress.phase)
                    .font(.subheadline)
                Text("\(progress.calls.count) Anfragen gestartet · \(progress.runningCount) laufen · \(progress.succeededCount) erfolgreich · \(progress.failedCount) fehlgeschlagen")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("meal.analysisProgress.counts")
                ForEach(progress.calls) { call in
                    if let result = call.result {
                        analysisRunRow(
                            title: "Anfrage \(call.id) · \(result.status == .succeeded ? "Erfolgreich" : "Fehlgeschlagen")",
                            subtitle: call.sampleNumber.map { "Schätzung \($0) · Versuch \(call.attemptNumber)" } ?? "Versuch \(call.attemptNumber)",
                            status: result.status,
                            modelIdentifier: result.modelIdentifier,
                            providerIdentifier: result.providerIdentifier,
                            requestedAt: result.requestedAt ?? call.requestedAt,
                            clarificationQuestion: result.clarificationQuestion,
                            clarificationAnswer: result.clarificationAnswer,
                            energyKilocalories: result.energyKilocalories,
                            inputTokens: result.inputTokens,
                            outputTokens: result.outputTokens,
                            costUSD: result.costUSD,
                            errorMessage: result.errorMessage
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                ProgressView()
                                Text("Anfrage \(call.id) · Antwort steht aus")
                                    .font(.subheadline.bold())
                            }
                            Text(call.sampleNumber.map { "Schätzung \($0) · Versuch \(call.attemptNumber)" } ?? "Versuch \(call.attemptNumber)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            LiveAnalysisStatusView(call: call)
                            LiveJSONStreamView(text: call.streamedJSON, callID: call.id)
                        }
                    }
                }
            }
            .padding(QuantLayout.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .background,
                in: .rect(cornerRadius: QuantLayout.cardCornerRadius)
            )
        }
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

    private func wholeNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }

    private func energyKilocalories(
        in revision: MealAnalysisRevision,
        portionMultipliers: PortionMultiplierSnapshot
    ) -> Double? {
        portionMultipliers.scaledValue(for: .energy, in: revision)
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
            .padding(QuantLayout.cardPadding)
            .background(
                .background,
                in: .rect(cornerRadius: QuantLayout.cardCornerRadius)
            )
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
                        .focused($focusedField, equals: .description)
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
        } else if meal.analysisState == .needsClarification {
            actionBar {
                VStack(spacing: 10) {
                    TextField("Antwort eingeben", text: $clarificationAnswer, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .clarification)
                        .disabled(isWorking || clarificationLimitReached)
                        .accessibilityIdentifier("meal.clarificationAnswer")

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
            .padding(.horizontal, QuantLayout.pageInset)
            .padding(.vertical, 12)
            .background(.bar)
            .accessibilityIdentifier("meal.actionBar")
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
            await MealAnalysisQueue.shared.answerClarification(
                clarificationAnswer,
                for: meal,
                in: modelContext,
                provider: analysisProvider,
                imageStorage: imageStorage
            )
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
            await MealAnalysisQueue.shared.correct(
                correction,
                for: meal,
                in: modelContext,
                provider: analysisProvider,
                imageStorage: imageStorage
            )
            correctionText = ""
            isWorking = false
        }
    }

    private func retryAnalysis() {
        isWorking = true
        Task {
            await MealAnalysisQueue.shared.analyze(
                meal,
                in: modelContext,
                provider: analysisProvider,
                imageStorage: imageStorage
            )
            isWorking = false
        }
    }

    private func saveDescriptionAndAnalyze() {
        isWorking = true
        do {
            try SwiftDataMealRepository(context: modelContext).addDescription(descriptionText, to: meal)
            descriptionText = ""
            Task {
                await MealAnalysisQueue.shared.analyze(
                    meal,
                    in: modelContext,
                    provider: analysisProvider,
                    imageStorage: imageStorage
                )
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

    private func duplicateMeal() {
        guard let onDuplicate, let revision = meal.activeRevision else { return }
        guard persistPortionMultiplier(for: revision) else { return }
        isWorking = true
        Task {
            do {
                try await onDuplicate(meal)
            } catch {
                alertMessage = "Die Mahlzeit konnte nicht dupliziert werden."
            }
            isWorking = false
        }
    }

    @discardableResult
    private func persistPortionMultiplier(for revision: MealAnalysisRevision) -> Bool {
        let normalized = portionAdjustment.multiplier
        guard revision.normalizedPortionMultiplier != normalized ||
            InitialAnalysisRunMetadata.componentMultipliers(from: revision.providerMetadata) != portionAdjustment.componentMultipliers else { return true }

        revision.portionMultiplier = normalized
        revision.providerMetadata = InitialAnalysisRunMetadata.settingComponentMultipliers(portionAdjustment.componentMultipliers, in: revision.providerMetadata)
        meal.modifiedAt = .now
        do {
            try modelContext.save()
            return true
        } catch {
            alertMessage = "Die angepasste Menge konnte nicht gespeichert werden."
            return false
        }
    }
}

private struct LiveAnalysisStatusView: View {
    let call: LiveAnalysisCall

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            VStack(alignment: .leading, spacing: 3) {
                Text(statusText)
                    .font(.caption.bold())
                    .accessibilityIdentifier("meal.analysisProgress.status.\(call.id)")
                Text("Bisher: \(durationText(from: call.requestedAt, to: endDate(at: timeline.date)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                timestamp("Gestartet", date: call.requestedAt)
                if let date = call.requestStartedAt {
                    timestamp("Übertragung gestartet", date: date)
                }
                if let date = call.responseStartedAt {
                    timestamp("Antwort begonnen", date: date)
                }
                if let date = call.firstContentAt {
                    timestamp("Erstes JSON", date: date)
                }
                if let date = call.responseCompletedAt {
                    timestamp("Antwort vollständig", date: date)
                }
            }
        }
    }

    private var statusText: String {
        if call.responseCompletedAt != nil {
            return "Antwort vollständig · Ergebnis wird geprüft …"
        }
        if call.firstContentAt != nil {
            return "JSON wird empfangen …"
        }
        if call.responseStartedAt != nil {
            return "Antwort begonnen · warte auf JSON …"
        }
        if call.requestStartedAt != nil {
            return "Anfrage und Bilder werden übertragen oder verarbeitet …"
        }
        return "Anfrage wird vorbereitet …"
    }

    private func timestamp(_ label: String, date: Date) -> some View {
        Text("\(label): \(date.formatted(.dateTime.hour().minute().second())) (+\(durationText(from: call.requestedAt, to: date)))")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func endDate(at currentDate: Date) -> Date {
        call.responseCompletedAt ?? currentDate
    }

    private func durationText(from startDate: Date, to endDate: Date) -> String {
        let seconds = max(0, Int(endDate.timeIntervalSince(startDate).rounded()))
        if seconds < 60 {
            return "\(seconds) s"
        }
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60)) min"
    }
}

private struct LiveJSONStreamView: View {
    private static let visibleLineCount: CGFloat = 10
    private static let lineHeight: CGFloat = 15

    let text: String
    let callID: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text.isEmpty ? "Warte auf erste JSON-Daten …" : text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(text.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Color.clear
                        .frame(height: 1)
                        .id("stream-end-\(callID)")
                }
            }
            .frame(height: Self.visibleLineCount * Self.lineHeight)
            .padding(8)
            .background(Color.black.opacity(0.06), in: .rect(cornerRadius: 8))
            .accessibilityIdentifier("meal.analysisProgress.stream.\(callID)")
            .onChange(of: text) {
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo("stream-end-\(callID)", anchor: .bottom)
                }
            }
        }
    }
}

@Observable
final class PortionAdjustmentDraft {
    var multiplier: Double

    var componentMultipliers: [String: Double]

    init(multiplier: Double, componentMultipliers: [String: Double] = [:]) {
        self.componentMultipliers = componentMultipliers
        self.multiplier = Self.normalized(multiplier)
    }

    func update(_ value: Double) {
        multiplier = Self.normalized(value)
    }

    func componentMultiplier(for component: FoodComponent) -> Double {
        componentMultipliers[component.id.uuidString] ?? 1
    }

    func updateComponent(_ component: FoodComponent, value: Double) {
        componentMultipliers[component.id.uuidString] = Self.normalized(value)
    }

    private static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max((value * 10).rounded() / 10, 0), 4)
    }
}

private struct PortionNutritionSummary: View {
    let revision: MealAnalysisRevision
    let adjustment: PortionAdjustmentDraft
    let onCommit: () -> Void

    var body: some View {
        let multiplier = adjustment.multiplier
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Kalorien")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(nutrientText(.energy, multiplier: multiplier))
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                }
                Spacer()
                if let weight = ComponentPortionScaling.weight(in: revision, multipliers: adjustment.componentMultipliers) {
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
                    value: Binding(
                        get: { adjustment.multiplier },
                        set: adjustment.update
                    ),
                    in: 0...4,
                    step: 0.1
                ) {
                    Text("Portionenmultiplikator")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("4")
                } onEditingChanged: { isEditing in
                    if !isEditing { onCommit() }
                }
                .accessibilityIdentifier("meal.portionMultiplier")
                .accessibilityValue("\(formattedMultiplier(multiplier))-fach")
            }

            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    macroTile("Protein", identifier: .protein, multiplier: multiplier)
                    macroTile("Kohlenhydrate", identifier: .carbohydrates, multiplier: multiplier)
                }
                GridRow {
                    macroTile("Fett", identifier: .fat, multiplier: multiplier)
                    macroTile("Ballaststoffe", identifier: .fiber, multiplier: multiplier)
                }
            }
        }
        .padding(QuantLayout.heroCardPadding)
        .background(
            .background,
            in: .rect(cornerRadius: QuantLayout.heroCardCornerRadius)
        )
    }

    private func macroTile(
        _ title: LocalizedStringKey,
        identifier: NutrientIdentifier,
        multiplier: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(nutrientText(identifier, multiplier: multiplier))
                .font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("meal.nutrient.\(identifier.rawValue)")
    }

    private func nutrientText(
        _ identifier: NutrientIdentifier,
        multiplier: Double
    ) -> String {
        guard let nutrient = ComponentPortionScaling.nutrient(
            identifier,
            in: revision,
            multipliers: adjustment.componentMultipliers
        ) else { return "–" }
        return "~\(formattedValue(nutrient.value * multiplier)) \(nutrient.unit.rawValue)"
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
}

private struct PortionComponentsSection: View {
    let revision: MealAnalysisRevision
    let adjustment: PortionAdjustmentDraft
    let onCommit: () -> Void

    var body: some View {
        let components = revision.components.sorted { $0.sortIndex < $1.sortIndex }
        if !components.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Bestandteile")
                    .font(.headline)
                ForEach(components) { component in
                    PortionComponentRow(
                        component: component,
                        adjustment: adjustment,
                        onCommit: onCommit
                    )
                    if component.id != components.last?.id {
                        Divider()
                    }
                }
            }
            .padding(QuantLayout.cardPadding)
            .background(
                .background,
                in: .rect(cornerRadius: QuantLayout.cardCornerRadius)
            )
        }
    }
}

private struct PortionComponentRow: View {
    let component: FoodComponent
    let adjustment: PortionAdjustmentDraft
    let onCommit: () -> Void

    private var multiplier: Double { adjustment.multiplier * adjustment.componentMultiplier(for: component) }

    private let displayedNutrients: [NutrientIdentifier] = [
        .energy,
        .protein,
        .carbohydrates,
        .fat,
        .fiber,
        .alcohol,
    ]

    var body: some View {
        DisclosureGroup {
            VStack(spacing: 9) {
                LabeledContent("Menge anpassen", value: "\(adjustment.componentMultiplier(for: component).formatted(.number.precision(.fractionLength(1))))×")
                Slider(
                    value: Binding(
                        get: { adjustment.componentMultiplier(for: component) },
                        set: { adjustment.updateComponent(component, value: $0) }
                    ),
                    in: 0...4,
                    step: 0.1,
                    onEditingChanged: { if !$0 { onCommit() } }
                ) { Text("Menge für \(component.name)") }
                .accessibilityIdentifier("meal.componentMultiplier.\(component.sortIndex)")
                .accessibilityValue("\(adjustment.componentMultiplier(for: component).formatted(.number.precision(.fractionLength(1))))-fach")
                ForEach(displayedNutrients, id: \.rawValue) { identifier in
                    LabeledContent(
                        identifier.reviewTitle,
                        value: nutrientText(identifier)
                    )
                }
            }
            .font(.subheadline)
            .padding(.top, 10)
        } label: {
            HStack {
                Text(component.name)
                    .font(.body.weight(.medium))
                Spacer()
                Text(weightText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityIdentifier("meal.component.\(component.sortIndex)")
        }
    }

    private var weightText: String {
        guard let weight = component.estimatedWeightGrams else { return "— g" }
        return "~\(wholeNumber(weight * multiplier)) g"
    }

    private func nutrientText(_ identifier: NutrientIdentifier) -> String {
        guard let nutrient = component.nutrients.first(where: {
            $0.identifierRawValue == identifier.rawValue
        }) else { return "—" }
        return "~\(formattedValue(nutrient.value * multiplier)) \(nutrient.unitRawValue)"
    }

    private func wholeNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }

    private func formattedValue(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0)))
    }
}

private struct PortionAdditionalNutrientsSection: View {
    let revision: MealAnalysisRevision
    let adjustment: PortionAdjustmentDraft
    @Binding var isExpanded: Bool

    var body: some View {
        let multiplier = adjustment.multiplier
        DisclosureGroup("Weitere Nährwerte", isExpanded: $isExpanded) {
            VStack(spacing: 10) {
                ForEach(additionalNutrients) { nutrient in
                    LabeledContent(
                        nutrient.knownIdentifier?.reviewTitle ?? nutrient.identifierRawValue,
                        value: "~\(formattedValue(ComponentPortionScaling.nutrient(nutrient, in: revision, multipliers: adjustment.componentMultipliers) * multiplier)) \(nutrient.unitRawValue)"
                    )
                }
            }
            .padding(.top, 12)
        }
        .padding(QuantLayout.cardPadding)
        .background(
            .background,
            in: .rect(cornerRadius: QuantLayout.cardCornerRadius)
        )
    }

    private var additionalNutrients: [NutrientValue] {
        let primary: Set<NutrientIdentifier> = [.energy, .protein, .carbohydrates, .fat, .fiber]
        return revision.nutrients
            .filter { nutrient in
                guard let identifier = nutrient.knownIdentifier else { return true }
                if identifier == .alcohol && nutrient.value == 0 { return false }
                return !primary.contains(identifier)
            }
            .sorted { $0.identifierRawValue < $1.identifierRawValue }
    }

    private func formattedValue(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0)))
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
        case .alcohol: "Alkohol"
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

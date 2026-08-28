import SwiftData
import SwiftUI

struct OpenRouterSettingsView: View {
    @Query(sort: \NutritionGoalPeriod.validFrom) private var goals: [NutritionGoalPeriod]
    @Query private var mealImages: [MealImage]
    @State private var viewModel: OpenRouterSettingsViewModel
    @AppStorage("weeklySummaryReminderEnabled") private var weeklyReminderEnabled = false
    @AppStorage(OpenRouterTrafficLogSettings.enabledKey) private var trafficLoggingEnabled = false
    @State private var weeklyReminderMessage: String?
    @State private var weeklyReminderMessageIsError = false
    @State private var isSchedulingTestReminder = false
    @State private var trafficLogMessage: String?
    @State private var trafficLogMessageIsError = false
    @State private var showsTrafficLog = false
    private let weeklyReminderScheduler = WeeklySummaryNotificationScheduler()

    init(viewModel: OpenRouterSettingsViewModel = OpenRouterSettingsViewModel()) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            Form {
                NutritionGoalSettingsSection(goals: goals)

                Section {
                    Toggle("Sonntags erinnern", isOn: Binding(
                        get: { weeklyReminderEnabled },
                        set: updateWeeklyReminder
                    ))
                    .accessibilityIdentifier("settings.weeklySummaryReminder")

                    Button {
                        scheduleTestReminder()
                    } label: {
                        HStack {
                            Text("Test-Erinnerung erstellen")
                            Spacer()
                            if isSchedulingTestReminder {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isSchedulingTestReminder)
                    .accessibilityIdentifier("settings.createWeeklySummaryTestReminder")

                    if let weeklyReminderMessage {
                        Text(weeklyReminderMessage)
                            .font(.footnote)
                            .foregroundStyle(weeklyReminderMessageIsError ? Color.orange : Color.secondary)
                    }
                } header: {
                    Text("Wochenübersicht")
                } footer: {
                    Text("Eine lokale Erinnerung erscheint sonntags gegen 20:00 Uhr. Die Übersicht wird erst beim Öffnen der App aus bestätigten Mahlzeiten berechnet.")
                }

                Section {
                    HStack {
                        Text("API-Schlüssel")
                        Spacer()
                        Label(
                            viewModel.hasStoredAPIKey ? "Gespeichert" : "Nicht eingerichtet",
                            systemImage: viewModel.hasStoredAPIKey ? "checkmark.circle.fill" : "exclamationmark.circle"
                        )
                        .lineLimit(1)
                        .foregroundStyle(viewModel.hasStoredAPIKey ? .green : .secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    SecureField("Neuen API-Schlüssel eingeben", text: $viewModel.replacementAPIKey)
                        .textContentType(.password)
                        .accessibilityIdentifier("settings.openRouterAPIKey")

                    LabeledContent("Modell") {
                        Menu {
                            if viewModel.modelOptions.isEmpty {
                                Text("Zuerst Modelle laden")
                            }
                            ForEach(viewModel.modelOptions) { model in
                                Button(model.name) {
                                    viewModel.modelIdentifier = model.id
                                }
                            }
                        } label: {
                            Text(selectedModelName)
                                .lineLimit(1)
                        }
                        .accessibilityIdentifier("settings.openRouterModelPicker")
                    }

                    Button {
                        Task { await viewModel.loadModelOptions() }
                    } label: {
                        HStack {
                            Text(viewModel.modelOptions.isEmpty ? "Passende Modelle laden" : "Modellliste aktualisieren")
                            Spacer()
                            if viewModel.isLoadingModels {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(viewModel.isLoadingModels || !viewModel.hasStoredAPIKey)
                    .accessibilityIdentifier("settings.loadOpenRouterModels")

                    DisclosureGroup("Erweiterte Modellauswahl") {
                        TextField("anbieter/modell", text: $viewModel.modelIdentifier)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityLabel("OpenRouter Modell-ID")
                            .accessibilityIdentifier("settings.openRouterModel")
                    }

                    Button("Konfiguration speichern") {
                        viewModel.save()
                    }

                    Button {
                        Task { await viewModel.testConfiguration() }
                    } label: {
                        HStack {
                            Text("Verbindung testen")
                            Spacer()
                            if viewModel.isTesting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(viewModel.isTesting)
                    .accessibilityIdentifier("settings.testOpenRouter")

                    if viewModel.hasStoredAPIKey {
                        Button("API-Schlüssel entfernen", role: .destructive) {
                            viewModel.removeAPIKey()
                        }
                    }
                } header: {
                    Text("OpenRouter")
                } footer: {
                    Text("Der API-Schlüssel liegt ausschließlich im iOS-Schlüsselbund. Für eine neue Mahlzeit und nach jeder beantworteten Rückfrage werden drei parallele Analysen berechnet; dadurch entstehen jeweils ungefähr dreifache API-Kosten.")
                }

                statusSection

                storageSection

                Section("Datenschutz") {
                    Label("Keine Werbung, Analytik-SDKs oder unnötige Tracker", systemImage: "hand.raised.fill")
                    Text("Mahlzeiten, Ziele und Fotos werden lokal in der App gespeichert. Fotos bleiben erhalten, solange der zugehörige Eintrag gespeichert ist.")
                    Text("Nur bei einer Analyse werden die zugehörigen Fotos und dein Kommentar an OpenRouter sowie den ausgewählten Modellanbieter gesendet. Für die erste Schätzung und nach beantworteten Rückfragen geschieht dies dreimal parallel.")
                    Text("OpenRouter und einzelne Anbieter können unterschiedliche Datenschutz- und Aufbewahrungsrichtlinien haben. Die App sendet keine anderen Mahlzeiten. API-Schlüssel werden niemals protokolliert; das detaillierte lokale OpenRouter-Log ist standardmäßig ausgeschaltet.")
                }

                Section("App") {
                    LabeledContent("Version", value: appVersion)
                    Text("Alle Auswertungen sind Schätzungen und keine medizinische Beratung.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Logging aktivieren", isOn: $trafficLoggingEnabled)
                        .accessibilityIdentifier("settings.openRouterTrafficLogging")

                    Button {
                        showsTrafficLog = true
                    } label: {
                        Label("Log anzeigen", systemImage: "doc.text.magnifyingglass")
                    }
                    .accessibilityIdentifier("settings.openRouterTrafficLog")

                    Button("Log leeren", role: .destructive) {
                        clearTrafficLog()
                    }
                    .accessibilityIdentifier("settings.clearOpenRouterTrafficLog")

                    if let trafficLogMessage {
                        Text(trafficLogMessage)
                            .font(.footnote)
                            .foregroundStyle(trafficLogMessageIsError ? Color.orange : Color.secondary)
                    }
                } header: {
                    Text("OpenRouter-Log")
                } footer: {
                    Text("Speichert Anfragen und Antworten mit ISO-Zeitstempeln lokal auf diesem Gerät. Texte können Mahlzeitenkommentare und Prompts enthalten. API-Schlüssel werden ausgelassen; Bilder und andere Nichttext-Inhalte werden entfernt. Das Ausschalten löscht vorhandene Einträge nicht.")
                }
            }
            .navigationTitle("Einstellungen")
            .task {
                viewModel.load()
                if viewModel.hasStoredAPIKey {
                    await viewModel.loadModelOptions()
                }
            }
        }
        .sheet(isPresented: $showsTrafficLog) {
            OpenRouterTrafficLogView()
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
        return "\(version) (\(build))"
    }

    private var selectedModelName: String {
        if let selected = viewModel.modelOptions.first(where: { $0.id == viewModel.modelIdentifier }) {
            return selected.name
        }
        return viewModel.modelIdentifier.isEmpty ? "Bitte auswählen" : viewModel.modelIdentifier
    }

    private var storageSection: some View {
        Section("Datenspeicher") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text("Mahlzeiten")
                    Spacer(minLength: 12)
                    Label("Auf diesem Gerät", systemImage: "iphone")
                }
                .padding(.vertical, 10)

                Divider()

                HStack(spacing: 12) {
                    Text("iCloud-Synchronisierung")
                    Spacer(minLength: 12)
                    Text(NutritionStoreMode.current == .cloudKit ? "Aktiv" : "Vorbereitet")
                        .foregroundStyle(NutritionStoreMode.current == .cloudKit ? Color.green : Color.secondary)
                }
                .padding(.vertical, 10)

                if photosNeedCloudAssetStorage {
                    Divider()
                    Label(
                        "Fotos bleiben derzeit ausschließlich auf diesem Gerät.",
                        systemImage: "photo.badge.exclamationmark"
                    )
                    .foregroundStyle(.orange)
                    .padding(.vertical, 10)
                }

                if NutritionStoreMode.current == .local {
                    Divider()
                    Text("Die CloudKit-Aktivierung ist bewusst ausgeschaltet, damit die App mit deinem Personal Team auf dem iPhone installiert werden kann. Später werden dafür eine iCloud-Berechtigung, ein Container und Cloud-Speicher für Fotos benötigt.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.storageSection")
        }
    }

    private var photosNeedCloudAssetStorage: Bool {
        CloudSyncReadinessAudit.issues(
            mode: .current,
            containsFileBackedImages: !mealImages.isEmpty
        ).contains(.fileBackedImagesNeedCloudAssetStorage)
    }

    private func updateWeeklyReminder(_ enabled: Bool) {
        if !enabled {
            weeklyReminderScheduler.disable()
            weeklyReminderEnabled = false
            weeklyReminderMessage = "Erinnerung deaktiviert."
            weeklyReminderMessageIsError = false
            return
        }

        Task {
            switch await weeklyReminderScheduler.enable() {
            case .enabled:
                weeklyReminderEnabled = true
                weeklyReminderMessage = "Erinnerung für Sonntag, 20:00 Uhr aktiviert."
                weeklyReminderMessageIsError = false
            case .denied:
                weeklyReminderEnabled = false
                weeklyReminderMessage = "Mitteilungen sind nicht erlaubt. Du kannst sie in den iOS-Einstellungen freigeben."
                weeklyReminderMessageIsError = true
            case .failed:
                weeklyReminderEnabled = false
                weeklyReminderMessage = "Die Erinnerung konnte nicht eingerichtet werden. Bitte versuche es erneut."
                weeklyReminderMessageIsError = true
            }
        }
    }

    private func scheduleTestReminder() {
        isSchedulingTestReminder = true
        Task {
            switch await weeklyReminderScheduler.scheduleTestNotification() {
            case .enabled:
                weeklyReminderMessage = "Test-Erinnerung erstellt. Sie erscheint in etwa 5 Sekunden, wenn Quant im Hintergrund ist."
                weeklyReminderMessageIsError = false
            case .denied:
                weeklyReminderMessage = "Mitteilungen sind nicht erlaubt. Du kannst sie in den iOS-Einstellungen freigeben."
                weeklyReminderMessageIsError = true
            case .failed:
                weeklyReminderMessage = "Die Test-Erinnerung konnte nicht erstellt werden. Bitte versuche es erneut."
                weeklyReminderMessageIsError = true
            }
            isSchedulingTestReminder = false
        }
    }

    private func clearTrafficLog() {
        Task {
            do {
                try await FileOpenRouterTrafficLog.shared.clear()
                trafficLogMessage = "Log geleert."
                trafficLogMessageIsError = false
            } catch {
                trafficLogMessage = "Das Log konnte nicht geleert werden."
                trafficLogMessageIsError = true
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let statusMessage = viewModel.statusMessage {
            Section {
                Label(statusMessage, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }

        switch viewModel.testState {
        case .idle:
            EmptyView()
        case .failure(let message):
            Section("Konfiguration") {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        case .success(let check):
            Section("Konfiguration") {
                Label("Verbindung erfolgreich", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                LabeledContent("Modell", value: check.modelName)
                capabilityRow("Bildeingabe", isSupported: check.supportsImageInput)
                capabilityRow("Strukturierte Ausgabe", isSupported: check.supportsStructuredOutput)

                if !check.supportsImageInput || !check.supportsStructuredOutput {
                    Text("Dieses Modell erfüllt noch nicht alle Anforderungen für die Ernährungsanalyse.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func capabilityRow(_ title: LocalizedStringKey, isSupported: Bool) -> some View {
        LabeledContent(title) {
            Label(
                isSupported ? "Unterstützt" : "Nicht unterstützt",
                systemImage: isSupported ? "checkmark.circle" : "xmark.circle"
            )
            .foregroundStyle(isSupported ? .green : .orange)
        }
    }
}

private struct OpenRouterTrafficLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [OpenRouterTrafficLogEntry] = []
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            content
            .navigationTitle("OpenRouter-Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                        .accessibilityIdentifier("settings.closeOpenRouterTrafficLog")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Aktualisieren", systemImage: "arrow.clockwise") {
                        load()
                    }
                    .disabled(isLoading)
                }
            }
            .onAppear {
                guard !hasLoaded else { return }
                hasLoaded = true
                load()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            ContentUnavailableView(
                "Log nicht verfügbar",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else if entries.isEmpty {
            ContentUnavailableView(
                isLoading ? "Requests werden geladen" : "Noch keine Einträge",
                systemImage: "list.bullet.rectangle",
                description: Text(
                    isLoading
                        ? "Du kannst diese Ansicht jederzeit schließen."
                        : "Bei aktiviertem Logging erscheinen zukünftige OpenRouter-Requests hier."
                )
            )
        } else {
            List(entries) { entry in
                NavigationLink {
                    OpenRouterTrafficLogDetailView(entry: entry)
                } label: {
                    OpenRouterTrafficLogRow(entry: entry)
                }
                .accessibilityIdentifier("settings.openRouterTrafficLogEntry.\(entry.id.uuidString)")
            }
            .accessibilityIdentifier("settings.openRouterTrafficLogList")
        }
    }

    @MainActor
    private func load() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        Task {
            defer { isLoading = false }
            do {
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing-openrouter-log-entry") {
                    entries = [Self.uiTestEntry]
                    return
                }
#endif
                let loadedEntries = try await FileOpenRouterTrafficLog.shared.entries()
                try Task.checkCancellation()
                entries = loadedEntries
            } catch is CancellationError {
                return
            } catch {
                entries = []
                errorMessage = "Die lokalen Logeinträge konnten nicht gelesen werden."
            }
        }
    }

#if DEBUG
    private static let uiTestEntry = OpenRouterTrafficLogEntry(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        requestedAt: Date(timeIntervalSince1970: 1_787_832_672.345),
        method: "POST",
        url: "https://openrouter.ai/api/v1/chat/completions",
        requestHeaders: ["Content-Type": "application/json"],
        requestText: #"{"prompt":"Bitte analysieren"}"#,
        respondedAt: Date(timeIntervalSince1970: 1_787_832_673.345),
        statusCode: 200,
        responseHeaders: ["Content-Type": "application/json"],
        responseText: uiTestResponseText,
        failureDescription: nil
    )

    private static let uiTestResponseText =
        #"{"result":"Testantwort","data":["#
        + String(repeating: #"{"id":"example/model","name":"Testmodell"},"#, count: 5_000)
        + "]}"
#endif
}

private struct OpenRouterTrafficLogRow: View {
    let entry: OpenRouterTrafficLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(entry.requestedAt.formatted(.dateTime.day().month().year().hour().minute().second()))
                    .font(.headline)
                Spacer()
                status
            }
            Text("\(entry.method) · \(endpoint)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var status: some View {
        if let statusCode = entry.statusCode {
            Text("HTTP \(statusCode)")
                .foregroundStyle((200..<300).contains(statusCode) ? Color.green : Color.orange)
        } else if entry.failureDescription != nil {
            Text("Fehler")
                .foregroundStyle(.orange)
        } else {
            Text("Offen")
                .foregroundStyle(.secondary)
        }
    }

    private var endpoint: String {
        guard let url = URL(string: entry.url) else { return entry.url }
        return url.lastPathComponent.isEmpty ? url.host ?? entry.url : url.lastPathComponent
    }
}

private struct OpenRouterTrafficLogDetailView: View {
    let entry: OpenRouterTrafficLogEntry

    var body: some View {
        Form {
            Section("Details") {
                LabeledContent("Zeitpunkt") {
                    Text(isoTimestamp(entry.requestedAt))
                        .textSelection(.enabled)
                }
                LabeledContent("Methode", value: entry.method)
                LabeledContent("Status", value: responseStatus)
                VStack(alignment: .leading, spacing: 6) {
                    Text("URL")
                        .foregroundStyle(.secondary)
                    Text(entry.url)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }

            Section("Request") {
                if !entry.requestHeaders.isEmpty {
                    LogTextBlock(title: "Header", text: formattedHeaders(entry.requestHeaders))
                }
                LogTextBlock(title: "Text", text: entry.requestText)
                    .accessibilityIdentifier("settings.openRouterTrafficLogRequest")
            }

            Section("Response") {
                if let respondedAt = entry.respondedAt {
                    LabeledContent("Zeitpunkt") {
                        Text(isoTimestamp(respondedAt))
                            .textSelection(.enabled)
                    }
                }
                if !entry.responseHeaders.isEmpty {
                    LogTextBlock(title: "Header", text: formattedHeaders(entry.responseHeaders))
                }
                if let failureDescription = entry.failureDescription {
                    LogTextBlock(title: "Fehler", text: failureDescription)
                } else {
                    LogTextBlock(title: "Text", text: entry.responseText ?? "Noch keine Response empfangen.")
                }
            }
            .accessibilityIdentifier("settings.openRouterTrafficLogResponse")
        }
        .navigationTitle("Request-Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var responseStatus: String {
        if let statusCode = entry.statusCode { return "HTTP \(statusCode)" }
        if entry.failureDescription != nil { return "Fehlgeschlagen" }
        return "Offen"
    }

    private func formattedHeaders(_ headers: [String: String]) -> String {
        headers
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }

    private func isoTimestamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .colon))
    }
}

private struct LogTextBlock: View {
    let title: String
    private let preview: OpenRouterTrafficLogTextPreview

    init(title: String, text: String) {
        self.title = title
        preview = OpenRouterTrafficLogTextPreview(text: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: preview.text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if preview.omittedCharacterCount > 0 {
                Text("Vorschau gekürzt – weitere \(preview.omittedCharacterCount.formatted()) Zeichen sind im lokalen Log gespeichert.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    OpenRouterSettingsView()
}

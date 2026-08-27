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
    private let weeklyReminderScheduler = WeeklySummaryNotificationScheduler()

    init(viewModel: OpenRouterSettingsViewModel = OpenRouterSettingsViewModel()) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            Form {
                NutritionGoalSettingsSection(goals: goals)

                DinnerPreferenceSettingsSection()

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
                    Text("Der API-Schlüssel liegt ausschließlich im iOS-Schlüsselbund. Für eine neue Mahlzeit werden drei parallele Analysen berechnet; dadurch können ungefähr dreifache API-Kosten entstehen.")
                }

                statusSection

                storageSection

                Section("Datenschutz") {
                    Label("Keine Werbung, Analytik-SDKs oder unnötige Tracker", systemImage: "hand.raised.fill")
                    Text("Mahlzeiten, Ziele, Essenspräferenzen, Abendessenvorschläge und Fotos werden lokal in der App gespeichert. Fotos bleiben erhalten, solange der zugehörige Eintrag gespeichert ist.")
                    Text("Nur bei einer Analyse werden die zugehörigen Fotos und dein Kommentar an OpenRouter sowie den ausgewählten Modellanbieter gesendet. Für die erste Schätzung geschieht dies dreimal parallel.")
                    Text("Beim Erstellen von Abendessenvorschlägen werden dein Restbudget, deine Essenspräferenzen und die angegebenen vorhandenen Zutaten einmal an OpenRouter sowie den ausgewählten Modellanbieter gesendet.")
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

                    NavigationLink {
                        OpenRouterTrafficLogView()
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
                    Text("Speichert Anfragen und Antworten mit ISO-Zeitstempeln lokal auf diesem Gerät. Texte können Mahlzeitenkommentare und Prompts enthalten. API-Schlüssel werden ausgelassen; Bilder und andere Nichttext-Inhalte werden gekürzt. Das Ausschalten löscht vorhandene Einträge nicht.")
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
                weeklyReminderMessage = "Test-Erinnerung erstellt. Sie erscheint in etwa 5 Sekunden, wenn Qant im Hintergrund ist."
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
    private static let maximumDisplayedBytes = 256 * 1_024

    @State private var contents = ""
    @State private var isLoading = true
    @State private var isTruncated = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Log wird geladen …")
            } else if let errorMessage {
                ContentUnavailableView(
                    "Log nicht verfügbar",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if contents.isEmpty {
                ContentUnavailableView(
                    "Noch keine Einträge",
                    systemImage: "doc.text",
                    description: Text("Bei aktiviertem Logging erscheinen zukünftige OpenRouter-Anfragen hier.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if isTruncated {
                            Label(
                                "Es werden die neuesten 256 KB angezeigt. Ältere Einträge bleiben gespeichert.",
                                systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90"
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }

                        Text(verbatim: contents)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("OpenRouter-Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Aktualisieren", systemImage: "arrow.clockwise") {
                Task { await load() }
            }
        }
        .task { await load() }
    }

    @MainActor
    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let snapshot = try await FileOpenRouterTrafficLog.shared.snapshot(
                maximumBytes: Self.maximumDisplayedBytes
            )
            try Task.checkCancellation()
            contents = snapshot.contents
            isTruncated = snapshot.isTruncated
        } catch is CancellationError {
            return
        } catch {
            contents = ""
            isTruncated = false
            errorMessage = "Die lokale Logdatei konnte nicht gelesen werden."
        }
    }
}

#Preview {
    OpenRouterSettingsView()
}

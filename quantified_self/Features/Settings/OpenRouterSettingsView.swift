import SwiftData
import SwiftUI

struct OpenRouterSettingsView: View {
    @Query(sort: \NutritionGoalPeriod.validFrom) private var goals: [NutritionGoalPeriod]
    @Query private var mealImages: [MealImage]
    @State private var viewModel: OpenRouterSettingsViewModel
    @AppStorage("weeklySummaryReminderEnabled") private var weeklyReminderEnabled = false
    @State private var weeklyReminderMessage: String?
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
                    if let weeklyReminderMessage {
                        Text(weeklyReminderMessage)
                            .font(.footnote)
                            .foregroundStyle(weeklyReminderEnabled ? Color.secondary : Color.orange)
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

                    TextField("anbieter/modell", text: $viewModel.modelIdentifier)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("OpenRouter Modell-ID")
                        .accessibilityIdentifier("settings.openRouterModel")

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
                    Text("Der API-Schlüssel liegt ausschließlich im iOS-Schlüsselbund. Die Modell-ID enthält keine Zugangsdaten.")
                }

                statusSection

                Section("Datenspeicher") {
                    LabeledContent("Mahlzeiten") {
                        Label("Auf diesem Gerät", systemImage: "iphone")
                    }
                    LabeledContent("iCloud-Synchronisierung") {
                        Text(NutritionStoreMode.current == .cloudKit ? "Aktiv" : "Vorbereitet")
                            .foregroundStyle(NutritionStoreMode.current == .cloudKit ? Color.green : Color.secondary)
                    }
                    if CloudSyncReadinessAudit.issues(
                        mode: .current,
                        containsFileBackedImages: !mealImages.isEmpty
                    ).contains(.fileBackedImagesNeedCloudAssetStorage) {
                        Label(
                            "Fotos bleiben derzeit ausschließlich auf diesem Gerät.",
                            systemImage: "photo.badge.exclamationmark"
                        )
                        .foregroundStyle(.orange)
                    }
                    if NutritionStoreMode.current == .local {
                        Text("Die CloudKit-Aktivierung ist bewusst ausgeschaltet, damit die App mit deinem Personal Team auf dem iPhone installiert werden kann. Später werden dafür eine iCloud-Berechtigung, ein Container und Cloud-Speicher für Fotos benötigt.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Datenschutz") {
                    Text("Für die spätere Analyse werden Mahlzeitenfotos und dein Kommentar an OpenRouter und den ausgewählten Modellanbieter gesendet.")
                    Text("Anbieter können unterschiedliche Datenschutz- und Aufbewahrungsrichtlinien haben. Nur beim Start einer Analyse werden Mahlzeitendaten übertragen.")
                }
            }
            .navigationTitle("Einstellungen")
            .onAppear { viewModel.load() }
        }
    }

    private func updateWeeklyReminder(_ enabled: Bool) {
        if !enabled {
            weeklyReminderScheduler.disable()
            weeklyReminderEnabled = false
            weeklyReminderMessage = "Erinnerung deaktiviert."
            return
        }

        Task {
            switch await weeklyReminderScheduler.enable() {
            case .enabled:
                weeklyReminderEnabled = true
                weeklyReminderMessage = "Erinnerung für Sonntag, 20:00 Uhr aktiviert."
            case .denied:
                weeklyReminderEnabled = false
                weeklyReminderMessage = "Mitteilungen sind nicht erlaubt. Du kannst sie in den iOS-Einstellungen freigeben."
            case .failed:
                weeklyReminderEnabled = false
                weeklyReminderMessage = "Die Erinnerung konnte nicht eingerichtet werden. Bitte versuche es erneut."
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

#Preview {
    OpenRouterSettingsView()
}

import AppIntents

struct QuickCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Essen erfassen"
    static let description = IntentDescription(
        "Öffnet die App direkt in der Erfassung einer neuen Mahlzeit."
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickCaptureRequestStore().requestCapture()
        return .result()
    }
}

struct QuantifiedSelfShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: QuickCaptureIntent(),
            phrases: [
                "Essen erfassen in \(.applicationName)",
                "Mahlzeit hinzufügen in \(.applicationName)",
            ],
            shortTitle: "Essen erfassen",
            systemImageName: "camera.fill"
        )
    }
}

import SwiftUI

struct DinnerPreferenceSettingsSection: View {
    @State private var preferences: DinnerPreferences
    private let store: any DinnerPreferenceStoring

    init(store: any DinnerPreferenceStoring = UserDefaultsDinnerPreferenceStore()) {
        self.store = store
        _preferences = State(initialValue: store.preferences)
    }

    var body: some View {
        Section {
            Picker("Ernährungsweise", selection: $preferences.dietaryStyle) {
                ForEach(DietaryStyle.allCases, id: \.self) { style in
                    Text(style.title).tag(style)
                }
            }
            preferenceField(
                title: "Allergien und Unverträglichkeiten",
                explanation: "Lebensmittel, die keinesfalls vorgeschlagen werden dürfen.",
                prompt: "z. B. Nüsse, Laktose",
                text: $preferences.allergies,
                identifier: "settings.dinnerPreferences.allergies"
            )
            preferenceField(
                title: "Ausgeschlossene Zutaten",
                explanation: "Zutaten, die du nicht magst oder vermeiden möchtest.",
                prompt: "z. B. Pilze, Fenchel",
                text: $preferences.excludedIngredients,
                identifier: "settings.dinnerPreferences.excludedIngredients"
            )
            preferenceField(
                title: "Bevorzugte Küchen",
                explanation: "Küchenrichtungen, an denen sich die Vorschläge orientieren sollen.",
                prompt: "z. B. italienisch, levantinisch",
                text: $preferences.preferredCuisines,
                identifier: "settings.dinnerPreferences.preferredCuisines"
            )
            VStack(alignment: .leading, spacing: 6) {
                Text("Zubereitungszeit")
                    .font(.subheadline.weight(.semibold))
                Stepper(
                    "Maximal \(preferences.maximumPreparationMinutes) Minuten",
                    value: $preferences.maximumPreparationMinutes,
                    in: 10...180,
                    step: 5
                )
                .accessibilityIdentifier("settings.dinnerPreferences.preparationTime")
            }
            .padding(.vertical, 2)
            preferenceField(
                title: "Küchenausstattung",
                explanation: "Geräte, die für die Zubereitung verwendet werden können.",
                prompt: "z. B. Ofen, Mixer, Airfryer",
                text: $preferences.kitchenEquipment,
                identifier: "settings.dinnerPreferences.kitchenEquipment"
            )
            preferenceField(
                title: "Vorhandene Zutaten",
                explanation: "Vorräte, die bei Vorschlägen bevorzugt verwendet werden sollen.",
                prompt: "z. B. Brokkoli, Reis, Tofu",
                text: $preferences.availableIngredients,
                identifier: "settings.dinnerPreferences.availableIngredients"
            )
        } header: {
            Text("Essenspräferenzen")
        } footer: {
            Text("Diese Angaben bleiben lokal und werden nur beim Erstellen von Abendessenvorschlägen an den ausgewählten Modellanbieter gesendet. Vorhandene Zutaten bleiben für die nächste Anfrage gespeichert.")
        }
        .onChange(of: preferences) { _, newValue in
            store.preferences = newValue
        }
    }

    private func preferenceField(
        title: String,
        explanation: String,
        prompt: String,
        text: Binding<String>,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(prompt, text: text, axis: .vertical)
                .lineLimit(1...3)
                .accessibilityLabel(title)
                .accessibilityHint(explanation)
                .accessibilityIdentifier(identifier)
        }
        .padding(.vertical, 3)
    }
}

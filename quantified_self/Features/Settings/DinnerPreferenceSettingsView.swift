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
            TextField("z. B. Nüsse, Laktose", text: $preferences.allergies, axis: .vertical)
                .accessibilityLabel("Allergien und Unverträglichkeiten")
            TextField("z. B. Pilze, Fenchel", text: $preferences.excludedIngredients, axis: .vertical)
                .accessibilityLabel("Ausgeschlossene Zutaten")
            TextField("z. B. italienisch, levantinisch", text: $preferences.preferredCuisines, axis: .vertical)
                .accessibilityLabel("Bevorzugte Küchen")
            Stepper(
                "Maximal \(preferences.maximumPreparationMinutes) Minuten",
                value: $preferences.maximumPreparationMinutes,
                in: 10...180,
                step: 5
            )
            TextField("z. B. Ofen, Mixer, Airfryer", text: $preferences.kitchenEquipment, axis: .vertical)
                .accessibilityLabel("Küchenausstattung")
            TextField("z. B. Brokkoli, Reis, Tofu", text: $preferences.availableIngredients, axis: .vertical)
                .accessibilityLabel("Vorhandene Zutaten")
        } header: {
            Text("Essenspräferenzen")
        } footer: {
            Text("Diese Angaben bleiben lokal und werden nur beim Erstellen von Abendessenvorschlägen an den ausgewählten Modellanbieter gesendet. Vorhandene Zutaten bleiben für die nächste Anfrage gespeichert.")
        }
        .onChange(of: preferences) { _, newValue in
            store.preferences = newValue
        }
    }
}

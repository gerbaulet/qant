import Foundation
import Testing
@testable import quantified_self

struct DinnerPreferenceStoreTests {
    @Test("Dinner preferences and available ingredients stay local and prefilled")
    func roundTrip() throws {
        let suite = "dinner-preference-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsDinnerPreferenceStore(defaults: defaults)
        store.preferences = DinnerPreferences(
            dietaryStyle: .vegan,
            allergies: "Erdnüsse",
            excludedIngredients: "Pilze",
            preferredCuisines: "Levantinisch",
            maximumPreparationMinutes: 30,
            kitchenEquipment: "Ofen",
            availableIngredients: "Kichererbsen, Spinat"
        )

        let restored = UserDefaultsDinnerPreferenceStore(defaults: defaults).preferences
        #expect(restored.dietaryStyle == .vegan)
        #expect(restored.allergies == "Erdnüsse")
        #expect(restored.maximumPreparationMinutes == 30)
        #expect(restored.availableIngredients == "Kichererbsen, Spinat")
    }
}

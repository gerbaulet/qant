import Foundation

enum DietaryStyle: String, CaseIterable, Codable, Sendable {
    case unrestricted
    case vegetarian
    case vegan

    var title: String {
        switch self {
        case .unrestricted: "Keine Einschränkung"
        case .vegetarian: "Vegetarisch"
        case .vegan: "Vegan"
        }
    }
}

struct DinnerPreferences: Equatable, Sendable {
    var dietaryStyle: DietaryStyle = .unrestricted
    var allergies = ""
    var excludedIngredients = ""
    var preferredCuisines = ""
    var maximumPreparationMinutes = 45
    var kitchenEquipment = ""
    var availableIngredients = ""

    var requestSummary: String {
        [
            "Ernährungsweise: \(dietaryStyle.title)",
            nonempty("Allergien/Unverträglichkeiten", allergies),
            nonempty("Ausgeschlossene Zutaten", excludedIngredients),
            nonempty("Bevorzugte Küchen", preferredCuisines),
            "Maximale Zubereitungszeit: \(maximumPreparationMinutes) Minuten",
            nonempty("Küchenausstattung", kitchenEquipment),
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }

    private func nonempty(_ label: String, _ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : "\(label): \(trimmed)"
    }
}

protocol DinnerPreferenceStoring: AnyObject {
    var preferences: DinnerPreferences { get set }
}

final class UserDefaultsDinnerPreferenceStore: DinnerPreferenceStoring {
    enum Key {
        static let dietaryStyle = "dinner.dietary-style"
        static let allergies = "dinner.allergies"
        static let excludedIngredients = "dinner.excluded-ingredients"
        static let preferredCuisines = "dinner.preferred-cuisines"
        static let maximumPreparationMinutes = "dinner.maximum-preparation-minutes"
        static let kitchenEquipment = "dinner.kitchen-equipment"
        static let availableIngredients = "dinner.available-ingredients"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var preferences: DinnerPreferences {
        get {
            let storedMinutes = defaults.integer(forKey: Key.maximumPreparationMinutes)
            return DinnerPreferences(
                dietaryStyle: DietaryStyle(
                    rawValue: defaults.string(forKey: Key.dietaryStyle) ?? ""
                ) ?? .unrestricted,
                allergies: defaults.string(forKey: Key.allergies) ?? "",
                excludedIngredients: defaults.string(forKey: Key.excludedIngredients) ?? "",
                preferredCuisines: defaults.string(forKey: Key.preferredCuisines) ?? "",
                maximumPreparationMinutes: storedMinutes > 0 ? storedMinutes : 45,
                kitchenEquipment: defaults.string(forKey: Key.kitchenEquipment) ?? "",
                availableIngredients: defaults.string(forKey: Key.availableIngredients) ?? ""
            )
        }
        set {
            defaults.set(newValue.dietaryStyle.rawValue, forKey: Key.dietaryStyle)
            defaults.set(newValue.allergies, forKey: Key.allergies)
            defaults.set(newValue.excludedIngredients, forKey: Key.excludedIngredients)
            defaults.set(newValue.preferredCuisines, forKey: Key.preferredCuisines)
            defaults.set(newValue.maximumPreparationMinutes, forKey: Key.maximumPreparationMinutes)
            defaults.set(newValue.kitchenEquipment, forKey: Key.kitchenEquipment)
            defaults.set(newValue.availableIngredients, forKey: Key.availableIngredients)
        }
    }
}

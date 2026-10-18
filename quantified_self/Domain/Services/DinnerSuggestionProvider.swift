import Foundation

struct DinnerNutrientBudget: Codable, Equatable, Sendable {
    let identifier: NutrientIdentifier
    let consumed: Double
    let target: Double?
    let unit: NutrientUnit

    var remaining: Double? { target.map { max($0 - consumed, 0) } }
    var isExceeded: Bool { target.map { consumed >= $0 } ?? false }
}

struct DinnerSuggestionRequest: Equatable, Sendable {
    let portionCount: Int
    let budgets: [DinnerNutrientBudget]
    let preferences: DinnerPreferences
    let availableIngredients: String
    let hasProvisionalValues: Bool
}

struct SuggestedIngredient: Codable, Equatable, Sendable {
    let name: String
    let amount: Double?
    let unit: String
}

struct SuggestedNutrient: Codable, Equatable, Sendable {
    let identifier: NutrientIdentifier
    let valuePerServing: Double
    let unit: NutrientUnit
}

struct SuggestedDinner: Codable, Equatable, Sendable {
    let name: String
    let fitSummary: String
    let ingredients: [SuggestedIngredient]
    let nutrients: [SuggestedNutrient]

    func nutrientValue(_ identifier: NutrientIdentifier) -> Double? {
        nutrients.first { $0.identifier == identifier }?.valuePerServing
    }
}

struct DinnerSuggestionResult: Equatable, Sendable {
    let suggestions: [SuggestedDinner]
    let modelIdentifier: String
    let providerIdentifier: String?
}

protocol DinnerSuggestionProviding {
    func suggestDinner(_ request: DinnerSuggestionRequest) async throws -> DinnerSuggestionResult
}

enum DinnerSuggestionError: Error, LocalizedError, Equatable {
    case invalidPortionCount
    case invalidResponse(String)
    case missingConfiguration

    var errorDescription: String? {
        switch self {
        case .invalidPortionCount:
            "Bitte wähle zwischen 1 und 12 Portionen."
        case .invalidResponse:
            "Das Modell hat keine verwertbaren Abendessen geliefert. Bitte versuche es erneut."
        case .missingConfiguration:
            "Bitte richte zuerst OpenRouter in den Einstellungen ein."
        }
    }
}

enum DinnerSuggestionValidator {
    private static let requiredNutrients: Set<NutrientIdentifier> = [
        .energy, .protein, .carbohydrates, .fat, .fiber,
    ]

    static func validate(_ result: DinnerSuggestionResult) throws {
        guard result.suggestions.count == 3 else {
            throw DinnerSuggestionError.invalidResponse("expected three suggestions")
        }
        let normalizedNames = Set(result.suggestions.map {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        guard normalizedNames.count == 3, !normalizedNames.contains("") else {
            throw DinnerSuggestionError.invalidResponse("suggestion names must be distinct")
        }
        for suggestion in result.suggestions {
            guard !suggestion.ingredients.isEmpty,
                  !suggestion.fitSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DinnerSuggestionError.invalidResponse("missing suggestion details")
            }
            guard suggestion.ingredients.allSatisfy({ ingredient in
                !ingredient.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    (ingredient.amount.map { $0.isFinite && $0 >= 0 } ?? true)
            }) else {
                throw DinnerSuggestionError.invalidResponse("invalid ingredient")
            }
            let identifiers = Set(suggestion.nutrients.map(\.identifier))
            guard requiredNutrients.isSubset(of: identifiers),
                  identifiers.count == suggestion.nutrients.count,
                  suggestion.nutrients.allSatisfy({ nutrient in
                      nutrient.valuePerServing.isFinite &&
                          nutrient.valuePerServing >= 0 &&
                          nutrient.unit == expectedUnit(for: nutrient.identifier)
                  }) else {
                throw DinnerSuggestionError.invalidResponse("invalid nutrients")
            }
        }
    }

    private static func expectedUnit(for identifier: NutrientIdentifier) -> NutrientUnit {
        identifier == .energy ? .kilocalorie : .gram
    }
}

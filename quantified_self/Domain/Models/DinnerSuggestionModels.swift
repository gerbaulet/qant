import Foundation
import SwiftData

@Model
final class DinnerSuggestionBatch {
    var id: UUID
    var createdAt: Date
    var portionCount: Int
    var availableIngredients: String
    var preferenceSummary: String
    var modelIdentifier: String
    var providerIdentifier: String?
    var promptVersion: Int
    var hasProvisionalInput: Bool
    var hadNoEnergyRoom: Bool
    var energyRemaining: Double?
    var proteinRemaining: Double?
    var carbohydratesRemaining: Double?
    var fatRemaining: Double?
    var fiberRemaining: Double?

    @Relationship(deleteRule: .cascade, inverse: \DinnerSuggestion.batch)
    var suggestions: [DinnerSuggestion]

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        portionCount: Int,
        availableIngredients: String,
        preferenceSummary: String,
        modelIdentifier: String,
        providerIdentifier: String? = nil,
        promptVersion: Int = DinnerSuggestionPrompt.currentVersion,
        hasProvisionalInput: Bool,
        hadNoEnergyRoom: Bool,
        energyRemaining: Double?,
        proteinRemaining: Double?,
        carbohydratesRemaining: Double?,
        fatRemaining: Double?,
        fiberRemaining: Double?,
        suggestions: [DinnerSuggestion] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.portionCount = portionCount
        self.availableIngredients = availableIngredients
        self.preferenceSummary = preferenceSummary
        self.modelIdentifier = modelIdentifier
        self.providerIdentifier = providerIdentifier
        self.promptVersion = promptVersion
        self.hasProvisionalInput = hasProvisionalInput
        self.hadNoEnergyRoom = hadNoEnergyRoom
        self.energyRemaining = energyRemaining
        self.proteinRemaining = proteinRemaining
        self.carbohydratesRemaining = carbohydratesRemaining
        self.fatRemaining = fatRemaining
        self.fiberRemaining = fiberRemaining
        self.suggestions = suggestions
    }
}

@Model
final class DinnerSuggestion {
    var id: UUID
    var sortIndex: Int
    var name: String
    var fitSummary: String
    var isFavorite: Bool
    var batch: DinnerSuggestionBatch?

    @Relationship(deleteRule: .cascade, inverse: \DinnerSuggestionIngredient.suggestion)
    var ingredients: [DinnerSuggestionIngredient]

    @Relationship(deleteRule: .cascade, inverse: \DinnerSuggestionNutrient.suggestion)
    var nutrients: [DinnerSuggestionNutrient]

    init(
        id: UUID = UUID(),
        sortIndex: Int,
        name: String,
        fitSummary: String,
        isFavorite: Bool = false,
        batch: DinnerSuggestionBatch? = nil,
        ingredients: [DinnerSuggestionIngredient] = [],
        nutrients: [DinnerSuggestionNutrient] = []
    ) {
        self.id = id
        self.sortIndex = sortIndex
        self.name = name
        self.fitSummary = fitSummary
        self.isFavorite = isFavorite
        self.batch = batch
        self.ingredients = ingredients
        self.nutrients = nutrients
    }

    func nutrient(_ identifier: NutrientIdentifier) -> DinnerSuggestionNutrient? {
        nutrients.first { $0.identifierRawValue == identifier.rawValue }
    }
}

@Model
final class DinnerSuggestionIngredient {
    var id: UUID
    var sortIndex: Int
    var name: String
    var amount: Double?
    var unit: String
    var suggestion: DinnerSuggestion?

    init(
        id: UUID = UUID(),
        sortIndex: Int,
        name: String,
        amount: Double?,
        unit: String,
        suggestion: DinnerSuggestion? = nil
    ) {
        self.id = id
        self.sortIndex = sortIndex
        self.name = name
        self.amount = amount
        self.unit = unit
        self.suggestion = suggestion
    }
}

@Model
final class DinnerSuggestionNutrient {
    var id: UUID
    var identifierRawValue: String
    var valuePerServing: Double
    var unitRawValue: String
    var suggestion: DinnerSuggestion?

    init(
        id: UUID = UUID(),
        identifier: NutrientIdentifier,
        valuePerServing: Double,
        unit: NutrientUnit,
        suggestion: DinnerSuggestion? = nil
    ) {
        self.id = id
        self.identifierRawValue = identifier.rawValue
        self.valuePerServing = valuePerServing
        self.unitRawValue = unit.rawValue
        self.suggestion = suggestion
    }

    var identifier: NutrientIdentifier? {
        NutrientIdentifier(rawValue: identifierRawValue)
    }

    var unit: NutrientUnit? {
        NutrientUnit(rawValue: unitRawValue)
    }
}

enum DinnerSuggestionPrompt {
    static let currentVersion = 1
}

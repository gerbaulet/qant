import SwiftData

@MainActor
final class SwiftDataDinnerSuggestionRepository {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func save(
        request: DinnerSuggestionRequest,
        result: DinnerSuggestionResult
    ) throws -> DinnerSuggestionBatch {
        let suggestions = result.suggestions.enumerated().map { index, result in
            DinnerSuggestion(
                sortIndex: index,
                name: result.name,
                fitSummary: result.fitSummary,
                ingredients: result.ingredients.enumerated().map { ingredientIndex, ingredient in
                    DinnerSuggestionIngredient(
                        sortIndex: ingredientIndex,
                        name: ingredient.name,
                        amount: ingredient.amount,
                        unit: ingredient.unit
                    )
                },
                nutrients: result.nutrients.map {
                    DinnerSuggestionNutrient(
                        identifier: $0.identifier,
                        valuePerServing: $0.valuePerServing,
                        unit: $0.unit
                    )
                }
            )
        }
        func remaining(_ identifier: NutrientIdentifier) -> Double? {
            request.budgets.first { $0.identifier == identifier }?.remaining
        }
        let batch = DinnerSuggestionBatch(
            portionCount: request.portionCount,
            availableIngredients: request.availableIngredients,
            preferenceSummary: request.preferences.requestSummary,
            modelIdentifier: result.modelIdentifier,
            providerIdentifier: result.providerIdentifier,
            hasProvisionalInput: request.hasProvisionalValues,
            hadNoEnergyRoom: request.budgets.first(where: { $0.identifier == .energy })?.isExceeded ?? false,
            energyRemaining: remaining(.energy),
            proteinRemaining: remaining(.protein),
            carbohydratesRemaining: remaining(.carbohydrates),
            fatRemaining: remaining(.fat),
            fiberRemaining: remaining(.fiber),
            suggestions: suggestions
        )
        context.insert(batch)
        try context.save()
        return batch
    }

    func delete(_ suggestion: DinnerSuggestion) throws {
        guard let batch = suggestion.batch else {
            context.delete(suggestion)
            try context.save()
            return
        }
        if batch.suggestions.count <= 1 {
            context.delete(batch)
        } else {
            context.delete(suggestion)
        }
        try context.save()
    }

    func deleteNonFavorites(in batches: [DinnerSuggestionBatch]) throws {
        for batch in batches {
            let removable = batch.suggestions.filter { !$0.isFavorite }
            if removable.count == batch.suggestions.count {
                context.delete(batch)
            } else {
                removable.forEach(context.delete)
            }
        }
        try context.save()
    }
}

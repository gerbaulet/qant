import SwiftData
import Testing
@testable import quantified_self

@MainActor
struct DinnerSuggestionRepositoryTests {
    @Test("Every generated dinner is saved and bulk deletion preserves favorites")
    func saveAndDeleteNonFavorites() throws {
        let container = try NutritionModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let repository = SwiftDataDinnerSuggestionRepository(context: context)

        let batch = try repository.save(request: request(), result: result())
        #expect(batch.suggestions.count == 3)
        #expect(try context.fetch(FetchDescriptor<DinnerSuggestion>()).count == 3)
        #expect(try context.fetch(FetchDescriptor<DinnerSuggestionIngredient>()).count == 3)

        batch.suggestions[0].isFavorite = true
        try context.save()
        try repository.deleteNonFavorites(in: [batch])

        let remaining = try context.fetch(FetchDescriptor<DinnerSuggestion>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.isFavorite == true)
        #expect(try context.fetch(FetchDescriptor<DinnerSuggestionBatch>()).count == 1)
    }

    @Test("Deleting the last dinner also removes its empty generation batch")
    func deletingLastSuggestionRemovesBatch() throws {
        let container = try NutritionModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let repository = SwiftDataDinnerSuggestionRepository(context: context)
        let batch = try repository.save(request: request(), result: result())
        let suggestions = Array(batch.suggestions)

        try repository.delete(suggestions[0])
        try repository.delete(suggestions[1])
        try repository.delete(suggestions[2])

        #expect(try context.fetch(FetchDescriptor<DinnerSuggestionBatch>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<DinnerSuggestion>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<DinnerSuggestionIngredient>()).isEmpty)
    }

    private func request() -> DinnerSuggestionRequest {
        DinnerSuggestionRequest(
            portionCount: 4,
            budgets: [
                DinnerNutrientBudget(identifier: .energy, consumed: 1_600, target: 2_200, unit: .kilocalorie),
                DinnerNutrientBudget(identifier: .protein, consumed: 80, target: 130, unit: .gram),
            ],
            preferences: DinnerPreferences(dietaryStyle: .vegetarian),
            availableIngredients: "Spinat",
            hasProvisionalValues: true
        )
    }

    private func result() -> DinnerSuggestionResult {
        DinnerSuggestionResult(
            suggestions: (1...3).map { index in
                SuggestedDinner(
                    name: "Gericht \(index)",
                    fitSummary: "Passt zum Budget.",
                    ingredients: [SuggestedIngredient(name: "Zutat \(index)", amount: 100, unit: "g")],
                    nutrients: [
                        SuggestedNutrient(identifier: .energy, valuePerServing: 600, unit: .kilocalorie),
                        SuggestedNutrient(identifier: .protein, valuePerServing: 40, unit: .gram),
                        SuggestedNutrient(identifier: .carbohydrates, valuePerServing: 60, unit: .gram),
                        SuggestedNutrient(identifier: .fat, valuePerServing: 20, unit: .gram),
                        SuggestedNutrient(identifier: .fiber, valuePerServing: 15, unit: .gram),
                    ]
                )
            },
            modelIdentifier: "example/model",
            providerIdentifier: "Provider"
        )
    }
}

import Testing
@testable import quantified_self

struct DinnerSuggestionValidatorTests {
    @Test("Dinner nutrient identifiers require their matching units")
    func rejectsWrongUnit() {
        let result = DinnerSuggestionResult(
            suggestions: (1...3).map { index in
                SuggestedDinner(
                    name: "Gericht \(index)",
                    fitSummary: "Passt.",
                    ingredients: [SuggestedIngredient(name: "Gemüse", amount: 200, unit: "g")],
                    nutrients: [
                        SuggestedNutrient(identifier: .energy, valuePerServing: 600, unit: .gram),
                        SuggestedNutrient(identifier: .protein, valuePerServing: 40, unit: .gram),
                        SuggestedNutrient(identifier: .carbohydrates, valuePerServing: 60, unit: .gram),
                        SuggestedNutrient(identifier: .fat, valuePerServing: 20, unit: .gram),
                        SuggestedNutrient(identifier: .fiber, valuePerServing: 15, unit: .gram),
                    ]
                )
            },
            modelIdentifier: "example/model",
            providerIdentifier: nil
        )

        #expect(throws: DinnerSuggestionError.self) {
            try DinnerSuggestionValidator.validate(result)
        }
    }
}

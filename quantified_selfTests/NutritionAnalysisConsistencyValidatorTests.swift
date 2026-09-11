import Testing
@testable import Quant

struct NutritionAnalysisConsistencyValidatorTests {
    @Test("A coherent follow-up result is accepted")
    func acceptsCoherentResult() throws {
        try NutritionAnalysisConsistencyValidator.validate(result())
    }

    @Test("Duplicate components are rejected")
    func rejectsDuplicateComponents() {
        let duplicate = component(name: "Reis", weight: 240, energy: 320)
        let value = result(components: [duplicate, duplicate])

        #expect(throws: NutritionAnalysisError.self) {
            try NutritionAnalysisConsistencyValidator.validate(value)
        }
    }

    @Test("Component weights must approximately match total weight")
    func rejectsInconsistentWeight() {
        let value = result(
            weight: 480,
            components: [component(name: "Reis", weight: 900, energy: 640)]
        )

        #expect(throws: NutritionAnalysisError.self) {
            try NutritionAnalysisConsistencyValidator.validate(value)
        }
    }

    @Test("Component calories must approximately match total calories")
    func rejectsInconsistentComponentEnergy() {
        let value = result(
            components: [component(name: "Reis", weight: 480, energy: 1_000)]
        )

        #expect(throws: NutritionAnalysisError.self) {
            try NutritionAnalysisConsistencyValidator.validate(value)
        }
    }

    @Test("Calories must remain broadly compatible with macros")
    func rejectsInconsistentMacroEnergy() {
        let value = replacingNutrient(.energy, value: 1_400, in: result(components: []))

        #expect(throws: NutritionAnalysisError.self) {
            try NutritionAnalysisConsistencyValidator.validate(value)
        }
    }

    @Test("Calories from alcohol are included in the consistency check")
    func acceptsAlcoholEnergy() throws {
        try NutritionAnalysisConsistencyValidator.validate(wineResult(alcoholGrams: 35.5))
    }

    @Test("Alcohol calories still require a matching alcohol amount")
    func rejectsUnexplainedWineEnergy() {
        #expect(throws: NutritionAnalysisError.self) {
            try NutritionAnalysisConsistencyValidator.validate(wineResult(alcoholGrams: 0))
        }
    }

    private func result(
        weight: Double = 480,
        components: [AnalyzedFoodComponent]? = nil
    ) -> NutritionAnalysisResult {
        let base = NutritionAnalysisValidatorTests.validResult()
        return NutritionAnalysisResult(
            mealName: base.mealName,
            estimatedTotalWeightGrams: weight,
            confidence: base.confidence,
            uncertaintySummary: base.uncertaintySummary,
            clarificationQuestion: base.clarificationQuestion,
            nutrients: base.nutrients,
            components: components ?? [component(name: "Curry", weight: 480, energy: 640)],
            modelIdentifier: base.modelIdentifier,
            providerIdentifier: base.providerIdentifier
        )
    }

    private func component(name: String, weight: Double, energy: Double) -> AnalyzedFoodComponent {
        AnalyzedFoodComponent(
            name: name,
            estimatedWeightGrams: weight,
            nutrients: [
                AnalyzedNutrient(
                    identifier: .energy,
                    value: energy,
                    unit: .kilocalorie,
                    confidence: .medium,
                    provenance: .visualEstimate
                ),
            ]
        )
    }

    private func wineResult(alcoholGrams: Double) -> NutritionAnalysisResult {
        let values: [(NutrientIdentifier, Double)] = [
            (.energy, 285),
            (.protein, 0),
            (.carbohydrates, 9),
            (.fat, 0),
            (.fiber, 0),
            (.alcohol, alcoholGrams),
        ]
        return NutritionAnalysisResult(
            mealName: "Eine halbe Flasche Rotwein",
            estimatedTotalWeightGrams: 375,
            confidence: .high,
            uncertaintySummary: nil,
            clarificationQuestion: nil,
            nutrients: values.map { identifier, value in
                AnalyzedNutrient(
                    identifier: identifier,
                    value: value,
                    unit: NutritionAnalysisValidator.expectedUnit(for: identifier),
                    confidence: .high,
                    provenance: .textProvidedByUser
                )
            },
            components: [],
            modelIdentifier: "example/vision-model",
            providerIdentifier: "Example"
        )
    }

    private func replacingNutrient(
        _ identifier: NutrientIdentifier,
        value: Double,
        in result: NutritionAnalysisResult
    ) -> NutritionAnalysisResult {
        NutritionAnalysisResult(
            mealName: result.mealName,
            estimatedTotalWeightGrams: result.estimatedTotalWeightGrams,
            confidence: result.confidence,
            uncertaintySummary: result.uncertaintySummary,
            clarificationQuestion: result.clarificationQuestion,
            nutrients: result.nutrients.map { nutrient in
                guard nutrient.identifier == identifier else { return nutrient }
                return AnalyzedNutrient(
                    identifier: nutrient.identifier,
                    value: value,
                    unit: nutrient.unit,
                    confidence: nutrient.confidence,
                    provenance: nutrient.provenance
                )
            },
            components: result.components,
            modelIdentifier: result.modelIdentifier,
            providerIdentifier: result.providerIdentifier
        )
    }
}

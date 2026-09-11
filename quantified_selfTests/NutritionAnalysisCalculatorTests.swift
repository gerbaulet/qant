import Testing
@testable import Quant

struct NutritionAnalysisCalculatorTests {
    @Test("Totals and weight are deterministically summed from complete components")
    func sumsComponents() throws {
        let result = NutritionAnalysisValidatorTests.validResult(
            nutrients: NutritionAnalysisValidatorTests.coreNutrients
        )
        let components = [
            component(name: "Toast", weight: 37.5, basis: .per100Grams, values: [248, 9.0666666667, 45.3333333333, 2.9333333333, 6.6666666667]),
            component(name: "Käse", weight: 50, values: [175, 12, 0, 14, 0]),
            component(name: "Butter", weight: 5, values: [37, 0, 0, 4.1, 0]),
        ]
        let input = NutritionAnalysisResult(
            mealName: result.mealName,
            estimatedTotalWeightGrams: 999,
            confidence: result.confidence,
            uncertaintySummary: result.uncertaintySummary,
            clarificationQuestion: nil,
            nutrients: result.nutrients,
            components: components,
            modelIdentifier: result.modelIdentifier,
            providerIdentifier: result.providerIdentifier
        )

        let calculated = NutritionAnalysisCalculator.calculateTotals(from: input)

        #expect(calculated.estimatedTotalWeightGrams == 92.5)
        #expect(calculated.nutrients.first { $0.identifier == .energy }?.value == 305)
        let protein = try #require(calculated.nutrients.first { $0.identifier == .protein }?.value)
        #expect(abs(protein - 15.4) < 0.001)
        #expect(calculated.nutrients.count == 5)
    }

    @Test("Impossible energy density is rejected without a fixed calorie cap")
    func rejectsImpossibleEnergyDensity() {
        let component = component(name: "Toast mit Käse", weight: 92.5, values: [1_273, 15, 20, 20, 3])
        let input = NutritionAnalysisResult(
            mealName: "Toast mit Käse",
            estimatedTotalWeightGrams: 92.5,
            confidence: .low,
            uncertaintySummary: nil,
            clarificationQuestion: nil,
            nutrients: component.nutrients,
            components: [component],
            modelIdentifier: "example/model",
            providerIdentifier: nil
        )

        #expect(throws: NutritionAnalysisError.self) {
            try NutritionAnalysisConsistencyValidator.validate(input)
        }
    }

    private func component(
        name: String,
        weight: Double,
        basis: ComponentNutrientBasis = .consumedAmount,
        values: [Double]
    ) -> AnalyzedFoodComponent {
        let identifiers: [NutrientIdentifier] = [.energy, .protein, .carbohydrates, .fat, .fiber]
        return AnalyzedFoodComponent(
            name: name,
            estimatedWeightGrams: weight,
            nutrientBasis: basis,
            nutrients: zip(identifiers, values).map { identifier, value in
                AnalyzedNutrient(
                    identifier: identifier,
                    value: value,
                    unit: NutritionAnalysisValidator.expectedUnit(for: identifier),
                    confidence: .high,
                    provenance: .calculatedFromLabel
                )
            }
        )
    }
}

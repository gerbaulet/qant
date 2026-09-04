import Testing
@testable import Quant

struct NutritionAnalysisResultNormalizerTests {
    @Test("Empty and duplicate components do not invalidate an otherwise usable estimate")
    func removesUnusableComponents() {
        let base = NutritionAnalysisValidatorTests.validResult()
        let component = AnalyzedFoodComponent(
            name: " Reis ",
            estimatedWeightGrams: 200,
            nutrients: []
        )
        let result = NutritionAnalysisResult(
            mealName: " Mahlzeit ",
            estimatedTotalWeightGrams: base.estimatedTotalWeightGrams,
            confidence: base.confidence,
            uncertaintySummary: "  ",
            clarificationQuestion: " ",
            nutrients: base.nutrients,
            components: [component, component, AnalyzedFoodComponent(
                name: "   ",
                estimatedWeightGrams: nil,
                nutrients: []
            )],
            modelIdentifier: base.modelIdentifier,
            providerIdentifier: base.providerIdentifier
        )

        let normalized = NutritionAnalysisResultNormalizer.normalize(result)

        #expect(normalized.mealName == "Mahlzeit")
        #expect(normalized.uncertaintySummary == nil)
        #expect(normalized.clarificationQuestion == nil)
        #expect(normalized.components.count == 1)
        #expect(normalized.components.first?.name == "Reis")
    }
}

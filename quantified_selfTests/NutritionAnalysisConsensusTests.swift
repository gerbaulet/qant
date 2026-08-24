import Testing
@testable import quantified_self

struct NutritionAnalysisConsensusTests {
    @Test("Three similar initial analyses are averaged")
    func averagesSimilarResults() throws {
        let result = try NutritionAnalysisConsensus.combine([
            scaledResult(0.9),
            scaledResult(1.0),
            scaledResult(1.1),
        ])

        #expect(result.nutrients.first { $0.identifier == .energy }?.value == 640)
        #expect(result.clarificationQuestion == nil)
        #expect(result.confidence == .medium)
    }

    @Test("Strongly different initial analyses request a better description")
    func flagsStrongDeviation() throws {
        let result = try NutritionAnalysisConsensus.combine([
            scaledResult(0.5),
            scaledResult(1.0),
            scaledResult(1.5),
        ])

        #expect(result.confidence == .low)
        #expect(result.clarificationQuestion?.contains("drei Analysen") == true)
        #expect(result.uncertaintySummary?.contains("nicht ausreichend konsistent") == true)
    }

    private func scaledResult(_ factor: Double) -> NutritionAnalysisResult {
        let base = NutritionAnalysisValidatorTests.validResult()
        return NutritionAnalysisResult(
            mealName: base.mealName,
            estimatedTotalWeightGrams: base.estimatedTotalWeightGrams.map { $0 * factor },
            confidence: base.confidence,
            uncertaintySummary: base.uncertaintySummary,
            clarificationQuestion: base.clarificationQuestion,
            nutrients: base.nutrients.map { nutrient in
                AnalyzedNutrient(
                    identifier: nutrient.identifier,
                    value: nutrient.value * factor,
                    unit: nutrient.unit,
                    confidence: nutrient.confidence,
                    provenance: nutrient.provenance
                )
            },
            components: base.components,
            modelIdentifier: base.modelIdentifier,
            providerIdentifier: base.providerIdentifier
        )
    }
}

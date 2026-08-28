import Testing
@testable import Quant

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
        #expect(result.clarificationQuestion?.contains("35 % und 10 kcal") == true)
        #expect(result.uncertaintySummary?.contains("nicht ausreichend konsistent") == true)
    }

    @Test("Small calorie ranges do not ask even when their percentage is large")
    func ignoresSmallAbsoluteEnergySpread() throws {
        let result = try NutritionAnalysisConsensus.combine([
            result(energy: 2),
            result(energy: 2),
            result(energy: 4),
        ])

        #expect(result.clarificationQuestion == nil)
    }

    @Test("A ten calorie range asks only when it also reaches 35 percent")
    func requiresBothEnergyThresholds() throws {
        let significant = try NutritionAnalysisConsensus.combine([
            result(energy: 20),
            result(energy: 25),
            result(energy: 30),
        ])
        let relativelySmall = try NutritionAnalysisConsensus.combine([
            result(energy: 94),
            result(energy: 94),
            result(energy: 104),
        ])

        #expect(significant.clarificationQuestion != nil)
        #expect(relativelySmall.clarificationQuestion == nil)
    }

    @Test("Macro and optional weight differences no longer ask")
    func ignoresNonEnergyDifferences() throws {
        let result = try NutritionAnalysisConsensus.combine([
            result(energy: 100, protein: 1, weight: nil),
            result(energy: 100, protein: 50, weight: 100),
            result(energy: 100, protein: 100, weight: 1_000),
        ])

        #expect(result.clarificationQuestion == nil)
    }

    @Test("Two differently worded model questions preserve the first")
    func keepsFirstOfTwoModelQuestions() throws {
        let result = try NutritionAnalysisConsensus.combine([
            result(energy: 100, question: "Wie viel Milch war im Kaffee?"),
            result(energy: 100, question: "Wurde Zucker hinzugefügt?"),
            result(energy: 100),
        ])

        #expect(result.clarificationQuestion == "Wie viel Milch war im Kaffee?")
    }

    @Test("A final follow-up suppresses model and divergence questions")
    func suppressesQuestionsWhenClarificationIsDisallowed() throws {
        let result = try NutritionAnalysisConsensus.combine([
            result(energy: 200, question: "Wie viel Öl?"),
            result(energy: 640, question: "Wie groß war die Portion?"),
            result(energy: 1_000),
        ], allowsClarification: false)

        #expect(result.clarificationQuestion == nil)
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

    private func result(
        energy: Double,
        protein: Double? = nil,
        weight: Double? = 480,
        question: String? = nil
    ) -> NutritionAnalysisResult {
        let base = NutritionAnalysisValidatorTests.validResult()
        return NutritionAnalysisResult(
            mealName: base.mealName,
            estimatedTotalWeightGrams: weight,
            confidence: base.confidence,
            uncertaintySummary: base.uncertaintySummary,
            clarificationQuestion: question,
            nutrients: base.nutrients.map { nutrient in
                let value: Double
                switch nutrient.identifier {
                case .energy: value = energy
                case .protein: value = protein ?? nutrient.value
                default: value = nutrient.value
                }
                return AnalyzedNutrient(
                    identifier: nutrient.identifier,
                    value: value,
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

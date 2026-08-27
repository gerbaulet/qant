import Testing
@testable import quantified_self

struct NutritionAnalysisDriftValidatorTests {
    @Test("Small calorie changes need no new explanation")
    func acceptsSmallChange() throws {
        try NutritionAnalysisDriftValidator.validate(
            previous: result(energy: 640, summary: "Menge des Öls"),
            revised: result(energy: 739, summary: nil)
        )
    }

    @Test("Both absolute and relative change thresholds are required")
    func requiresBothThresholds() throws {
        try NutritionAnalysisDriftValidator.validate(
            previous: result(energy: 1_000, summary: nil),
            revised: result(energy: 1_150, summary: nil)
        )
        try NutritionAnalysisDriftValidator.validate(
            previous: result(energy: 400, summary: nil),
            revised: result(energy: 499, summary: nil)
        )
    }

    @Test("A material calorie change requires a new specific explanation")
    func rejectsUnexplainedMaterialChange() {
        #expect(throws: NutritionAnalysisError.self) {
            try NutritionAnalysisDriftValidator.validate(
                previous: result(energy: 640, summary: "Menge des Öls ist unklar"),
                revised: result(energy: 800, summary: "Menge des Öls ist unklar")
            )
        }
    }

    @Test("Exact absolute and relative boundaries require an explanation")
    func enforcesExactBoundaries() {
        #expect(throws: NutritionAnalysisError.self) {
            try NutritionAnalysisDriftValidator.validate(
                previous: result(energy: 500, summary: nil),
                revised: result(energy: 600, summary: nil)
            )
        }
    }

    @Test("A specifically explained material change is accepted")
    func acceptsExplainedMaterialChange() throws {
        try NutritionAnalysisDriftValidator.validate(
            previous: result(energy: 640, summary: "Menge des Öls ist unklar"),
            revised: result(
                energy: 800,
                summary: "Die bestätigten zwei Esslöffel Öl erhöhen die Energiemenge."
            )
        )
    }

    private func result(energy: Double, summary: String?) -> NutritionAnalysisResult {
        let base = NutritionAnalysisValidatorTests.validResult()
        return NutritionAnalysisResult(
            mealName: base.mealName,
            estimatedTotalWeightGrams: base.estimatedTotalWeightGrams,
            confidence: base.confidence,
            uncertaintySummary: summary,
            clarificationQuestion: base.clarificationQuestion,
            nutrients: base.nutrients.map { nutrient in
                guard nutrient.identifier == .energy else { return nutrient }
                return AnalyzedNutrient(
                    identifier: nutrient.identifier,
                    value: energy,
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

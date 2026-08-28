import Foundation
import Testing
@testable import Quant

struct NutritionAnalysisValidatorTests {
    @Test("A complete nonnegative analysis is accepted")
    func acceptsValidResult() throws {
        try NutritionAnalysisValidator.validate(Self.validResult())
    }

    @Test("Missing core nutrients are rejected")
    func rejectsMissingCoreNutrients() {
        let result = Self.validResult(nutrients: Array(Self.coreNutrients.dropLast()))

        #expect(throws: NutritionAnalysisError.self) {
            try NutritionAnalysisValidator.validate(result)
        }
    }

    @Test("Negative and non-finite values are rejected")
    func rejectsInvalidNumbers() {
        var nutrients = Self.coreNutrients
        nutrients[0] = AnalyzedNutrient(
            identifier: .energy,
            value: -.infinity,
            unit: .kilocalorie,
            confidence: .low,
            provenance: .visualEstimate
        )

        #expect(throws: NutritionAnalysisError.self) {
            try NutritionAnalysisValidator.validate(Self.validResult(nutrients: nutrients))
        }
    }

    @Test("Units must match their nutrient")
    func rejectsWrongUnit() {
        var nutrients = Self.coreNutrients
        nutrients[1] = AnalyzedNutrient(
            identifier: .protein,
            value: 20,
            unit: .milligram,
            confidence: .medium,
            provenance: .visualEstimate
        )

        #expect(throws: NutritionAnalysisError.self) {
            try NutritionAnalysisValidator.validate(Self.validResult(nutrients: nutrients))
        }
    }

    static let coreNutrients: [AnalyzedNutrient] = [
        nutrient(.energy, 640, .kilocalorie),
        nutrient(.protein, 34, .gram),
        nutrient(.carbohydrates, 71, .gram),
        nutrient(.fat, 22, .gram),
        nutrient(.fiber, 9, .gram),
        nutrient(.sugar, 8, .gram),
        nutrient(.saturatedFat, 6, .gram),
        nutrient(.sodium, 720, .milligram),
    ]

    static func validResult(
        nutrients: [AnalyzedNutrient] = coreNutrients,
        clarificationQuestion: String? = nil
    ) -> NutritionAnalysisResult {
        NutritionAnalysisResult(
            mealName: "Gemüsecurry mit Reis",
            estimatedTotalWeightGrams: 480,
            confidence: .medium,
            uncertaintySummary: "Menge des verwendeten Öls",
            clarificationQuestion: clarificationQuestion,
            nutrients: nutrients,
            components: [],
            modelIdentifier: "example/vision-model",
            providerIdentifier: "Example"
        )
    }

    private static func nutrient(
        _ identifier: NutrientIdentifier,
        _ value: Double,
        _ unit: NutrientUnit
    ) -> AnalyzedNutrient {
        AnalyzedNutrient(
            identifier: identifier,
            value: value,
            unit: unit,
            confidence: .medium,
            provenance: .mixedEstimate
        )
    }
}

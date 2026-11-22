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
        let result = Self.validResult(nutrients: Self.coreNutrients.filter { $0.identifier != .fiber })

        #expect(throws: NutritionAnalysisError.self) {
            try NutritionAnalysisValidator.validate(result)
        }
    }

    @Test("An analysis without components is rejected")
    func rejectsMissingComponents() {
        let result = Self.validResult(components: [])

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

    @Test("An uncertainty summary with 60 words is accepted")
    func acceptsUncertaintySummaryAtWordLimit() throws {
        let summary = Array(repeating: "Wort", count: 60).joined(separator: " ")

        try NutritionAnalysisValidator.validate(Self.validResult(uncertaintySummary: summary))
    }

    @Test("An uncertainty summary with more than 60 words is rejected")
    func rejectsUncertaintySummaryAboveWordLimit() {
        let summary = Array(repeating: "Wort", count: 61).joined(separator: " ")

        #expect(throws: NutritionAnalysisError.self) {
            try NutritionAnalysisValidator.validate(Self.validResult(uncertaintySummary: summary))
        }
    }

    static let coreNutrients: [AnalyzedNutrient] = [
        nutrient(.energy, 640, .kilocalorie),
        nutrient(.protein, 34, .gram),
        nutrient(.carbohydrates, 71, .gram),
        nutrient(.fat, 22, .gram),
        nutrient(.fiber, 9, .gram),
        nutrient(.alcohol, 0, .gram),
    ]

    static func validResult(
        nutrients: [AnalyzedNutrient] = coreNutrients,
        components: [AnalyzedFoodComponent]? = nil,
        clarificationQuestion: String? = nil,
        uncertaintySummary: String? = "Menge des verwendeten Öls"
    ) -> NutritionAnalysisResult {
        NutritionAnalysisResult(
            mealName: "Gemüsecurry mit Reis",
            estimatedTotalWeightGrams: 480,
            confidence: .medium,
            uncertaintySummary: uncertaintySummary,
            clarificationQuestion: clarificationQuestion,
            nutrients: nutrients,
            components: components ?? [AnalyzedFoodComponent(
                name: "Gemüsecurry mit Reis",
                estimatedWeightGrams: 480,
                nutrients: nutrients
            )],
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

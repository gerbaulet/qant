import Foundation
import Testing
@testable import Quant

struct NutritionAnalysisSamplingPolicyTests {
    @Test("A low-confidence visual plate requests two additional estimates")
    func samplesUncertainPlate() {
        let request = NutritionAnalysisRequest(
            images: [NutritionAnalysisImage(data: Data([1]))],
            userComment: "Pasta mit Sauce"
        )

        #expect(NutritionAnalysisSamplingPolicy.requiresAdditionalEstimates(
            request: request,
            result: visualResult(confidence: .low)
        ))
    }

    @Test("Recognized nutrition labels suppress additional estimates")
    func skipsLabeledMeal() {
        let request = NutritionAnalysisRequest(
            images: [NutritionAnalysisImage(data: Data([1]))],
            userComment: "Toast mit Käse",
            recognizedLabelText: ["Nährwerte pro 100 g Energie 248 kcal Protein 9 g"]
        )

        #expect(!NutritionAnalysisSamplingPolicy.requiresAdditionalEstimates(
            request: request,
            result: visualResult(confidence: .low)
        ))
    }

    @Test("Label-derived result provenance suppresses sampling when OCR misses the label")
    func skipsLabelDerivedResult() {
        let request = NutritionAnalysisRequest(
            images: [NutritionAnalysisImage(data: Data([1]))],
            userComment: nil
        )

        #expect(!NutritionAnalysisSamplingPolicy.requiresAdditionalEstimates(
            request: request,
            result: visualResult(confidence: .low, provenance: .calculatedFromLabel)
        ))
    }

    @Test("Concrete user quantities suppress additional estimates")
    func skipsExplicitQuantity() {
        let request = NutritionAnalysisRequest(
            images: [NutritionAnalysisImage(data: Data([1]))],
            userComment: "250 g Pasta mit Sauce"
        )

        #expect(!NutritionAnalysisSamplingPolicy.requiresAdditionalEstimates(
            request: request,
            result: visualResult(confidence: .low)
        ))
    }

    @Test("High confidence and clarification questions suppress sampling")
    func skipsWhenSamplingCannotHelp() {
        let request = NutritionAnalysisRequest(
            images: [NutritionAnalysisImage(data: Data([1]))],
            userComment: nil
        )

        #expect(!NutritionAnalysisSamplingPolicy.requiresAdditionalEstimates(
            request: request,
            result: visualResult(confidence: .high)
        ))
        #expect(!NutritionAnalysisSamplingPolicy.requiresAdditionalEstimates(
            request: request,
            result: visualResult(confidence: .low, clarificationQuestion: "Wie groß war der Teller?")
        ))
    }

    @Test("The complete result with median calories is selected")
    func selectsMedianResult() throws {
        let low = visualResult(energy: 410, confidence: .low)
        let high = visualResult(energy: 890, confidence: .low)
        let middle = visualResult(energy: 620, confidence: .low)

        let selected = try NutritionAnalysisSamplingPolicy.medianResult(from: [low, high, middle])

        #expect(selected.nutrients.first { $0.identifier == .energy }?.value == 620)
    }

    private func visualResult(
        energy: Double = 640,
        confidence: EstimateConfidence,
        clarificationQuestion: String? = nil,
        provenance: NutrientProvenance = .visualEstimate
    ) -> NutritionAnalysisResult {
        let nutrients = NutritionAnalysisValidatorTests.coreNutrients.map { nutrient in
            AnalyzedNutrient(
                identifier: nutrient.identifier,
                value: nutrient.identifier == .energy ? energy : nutrient.value,
                unit: nutrient.unit,
                confidence: confidence,
                provenance: provenance
            )
        }
        return NutritionAnalysisResult(
            mealName: "Pasta mit Sauce",
            estimatedTotalWeightGrams: 480,
            confidence: confidence,
            uncertaintySummary: confidence == .low ? "Die Portionsgröße ist schwer erkennbar." : nil,
            clarificationQuestion: clarificationQuestion,
            nutrients: nutrients,
            components: [],
            modelIdentifier: "example/vision-model",
            providerIdentifier: "Example"
        )
    }
}

import Foundation
import Testing
@testable import Quant

struct NutritionAnalysisSamplingPolicyTests {
    @Test("A plate without measured quantities requests two additional estimates")
    func samplesPlateWithoutMeasuredQuantity() {
        let request = NutritionAnalysisRequest(
            images: [NutritionAnalysisImage(data: Data([1]))],
            userComment: "Pasta mit Sauce"
        )

        #expect(NutritionAnalysisSamplingPolicy.requiresAdditionalEstimates(
            request: request,
            result: visualResult(confidence: .high)
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

    @Test("Model confidence and provenance do not suppress plate sampling")
    func ignoresModelClassificationForPlateSampling() {
        let request = NutritionAnalysisRequest(
            images: [NutritionAnalysisImage(data: Data([1]))],
            userComment: nil
        )

        #expect(NutritionAnalysisSamplingPolicy.requiresAdditionalEstimates(
            request: request,
            result: visualResult(confidence: .high, provenance: .calculatedFromLabel)
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

        let impreciseCountRequest = NutritionAnalysisRequest(
            images: [NutritionAnalysisImage(data: Data([1]))],
            userComment: "Eine Scheibe Brot und ein Stück Käse"
        )
        #expect(NutritionAnalysisSamplingPolicy.requiresAdditionalEstimates(
            request: impreciseCountRequest,
            result: visualResult(confidence: .high)
        ))
    }

    @Test("Clarification questions suppress sampling")
    func skipsOpenClarification() {
        let request = NutritionAnalysisRequest(
            images: [NutritionAnalysisImage(data: Data([1]))],
            userComment: nil
        )

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

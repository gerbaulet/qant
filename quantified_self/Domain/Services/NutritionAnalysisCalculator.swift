import Foundation

enum NutritionAnalysisCalculator {
    static func calculateTotals(from result: NutritionAnalysisResult) -> NutritionAnalysisResult {
        let core = NutritionAnalysisValidator.coreNutrients
        let components = result.components.map { component in
            AnalyzedFoodComponent(
                name: component.name,
                estimatedWeightGrams: component.estimatedWeightGrams,
                nutrientBasis: .consumedAmount,
                nutrients: component.nutrients.filter { core.contains($0.identifier) }
                    .map { nutrient in
                        guard
                            component.nutrientBasis == .per100Grams,
                            let weight = component.estimatedWeightGrams
                        else { return nutrient }
                        return AnalyzedNutrient(
                            identifier: nutrient.identifier,
                            value: nutrient.value * weight / 100,
                            unit: nutrient.unit,
                            confidence: nutrient.confidence,
                            provenance: nutrient.provenance == .label
                                ? .calculatedFromLabel
                                : nutrient.provenance
                        )
                    }
            )
        }
        let canSumComponents = !components.isEmpty && components.allSatisfy { component in
            core.allSatisfy { identifier in
                component.nutrients.contains { $0.identifier == identifier }
            }
        }

        let nutrients: [AnalyzedNutrient]
        if canSumComponents {
            nutrients = core.sorted { $0.rawValue < $1.rawValue }.compactMap { identifier in
                let values = components.compactMap { component in
                    component.nutrients.first { $0.identifier == identifier }
                }
                guard values.count == components.count, let first = values.first else { return nil }
                return AnalyzedNutrient(
                    identifier: identifier,
                    value: values.reduce(0) { $0 + $1.value },
                    unit: first.unit,
                    confidence: lowestConfidence(values.map(\.confidence)),
                    provenance: combinedProvenance(values.map(\.provenance))
                )
            }
        } else {
            nutrients = result.nutrients.filter { core.contains($0.identifier) }
        }

        let componentWeights = components.compactMap(\.estimatedWeightGrams)
        let totalWeight = !components.isEmpty && componentWeights.count == components.count
            ? componentWeights.reduce(0, +)
            : result.estimatedTotalWeightGrams

        return NutritionAnalysisResult(
            mealName: result.mealName,
            estimatedTotalWeightGrams: totalWeight,
            confidence: result.confidence,
            uncertaintySummary: result.uncertaintySummary,
            clarificationQuestion: result.clarificationQuestion,
            nutrients: nutrients,
            components: components,
            modelIdentifier: result.modelIdentifier,
            providerIdentifier: result.providerIdentifier,
            requestMetrics: result.requestMetrics
        )
    }

    private static func lowestConfidence(_ values: [EstimateConfidence]) -> EstimateConfidence {
        if values.contains(.low) { return .low }
        if values.contains(.medium) { return .medium }
        return .high
    }

    private static func combinedProvenance(_ values: [NutrientProvenance]) -> NutrientProvenance {
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return .mixedEstimate }
        return first
    }
}

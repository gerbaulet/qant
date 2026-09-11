import Foundation

enum NutritionAnalysisConsistencyValidator {
    private static let maximumRelativeDifference = 0.25
    private static let minimumWeightToleranceGrams = 50.0
    private static let minimumEnergyToleranceKilocalories = 75.0
    private static let maximumMacroRelativeDifference = 0.35
    private static let minimumMacroToleranceKilocalories = 120.0
    private static let maximumEnergyDensityKilocaloriesPerGram = 9.5
    private static let energyDensityRoundingToleranceKilocalories = 25.0

    static func validate(_ result: NutritionAnalysisResult) throws {
        try validateUniqueComponents(result.components)
        try validateComponentWeights(result)
        try validateComponentEnergy(result)
        try validateMacroEnergy(result)
        try validateEnergyDensity(result)
    }

    private static func validateUniqueComponents(_ components: [AnalyzedFoodComponent]) throws {
        let names = components.map { component in
            component.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        guard Set(names).count == names.count else {
            throw NutritionAnalysisError.invalidResult("Ein Bestandteil wurde mehrfach ausgegeben.")
        }
    }

    private static func validateComponentWeights(_ result: NutritionAnalysisResult) throws {
        guard
            !result.components.isEmpty,
            let totalWeight = result.estimatedTotalWeightGrams,
            result.components.allSatisfy({ $0.estimatedWeightGrams != nil })
        else { return }
        let componentWeight = result.components.compactMap(\.estimatedWeightGrams).reduce(0, +)
        let tolerance = max(minimumWeightToleranceGrams, totalWeight * maximumRelativeDifference)
        guard abs(componentWeight - totalWeight) <= tolerance else {
            throw NutritionAnalysisError.invalidResult("Bestandteilmengen und Gesamtgewicht stimmen nicht überein.")
        }
    }

    private static func validateComponentEnergy(_ result: NutritionAnalysisResult) throws {
        guard
            !result.components.isEmpty,
            let totalEnergy = nutrient(.energy, in: result.nutrients),
            result.components.allSatisfy({ nutrient(.energy, in: $0.nutrients) != nil })
        else { return }
        let componentEnergy = result.components.compactMap {
            nutrient(.energy, in: $0.nutrients)
        }.reduce(0, +)
        let tolerance = max(minimumEnergyToleranceKilocalories, totalEnergy * maximumRelativeDifference)
        guard abs(componentEnergy - totalEnergy) <= tolerance else {
            throw NutritionAnalysisError.invalidResult("Kalorien der Bestandteile und Gesamtkalorien stimmen nicht überein.")
        }
    }

    private static func validateMacroEnergy(_ result: NutritionAnalysisResult) throws {
        guard
            let energy = nutrient(.energy, in: result.nutrients),
            let protein = nutrient(.protein, in: result.nutrients),
            let carbohydrates = nutrient(.carbohydrates, in: result.nutrients),
            let fat = nutrient(.fat, in: result.nutrients),
            let fiber = nutrient(.fiber, in: result.nutrients),
            let alcohol = nutrient(.alcohol, in: result.nutrients)
        else { return }
        let macroEnergy = protein * 4 + carbohydrates * 4 + fat * 9 + fiber * 2 + alcohol * 7
        let tolerance = max(minimumMacroToleranceKilocalories, energy * maximumMacroRelativeDifference)
        guard abs(macroEnergy - energy) <= tolerance else {
            throw NutritionAnalysisError.invalidResult("Kalorien und Makronährstoffe stimmen nicht überein.")
        }
    }

    private static func validateEnergyDensity(_ result: NutritionAnalysisResult) throws {
        try validateEnergyDensity(
            weight: result.estimatedTotalWeightGrams,
            energy: nutrient(.energy, in: result.nutrients),
            field: "Die Gesamtmenge"
        )
        for component in result.components {
            try validateEnergyDensity(
                weight: component.estimatedWeightGrams,
                energy: nutrient(.energy, in: component.nutrients),
                field: "Der Bestandteil „\(component.name)“"
            )
        }
    }

    private static func validateEnergyDensity(
        weight: Double?,
        energy: Double?,
        field: String
    ) throws {
        guard let weight, let energy, weight > 0 else { return }
        let maximumEnergy = weight * maximumEnergyDensityKilocaloriesPerGram +
            energyDensityRoundingToleranceKilocalories
        guard energy <= maximumEnergy else {
            throw NutritionAnalysisError.invalidResult(
                "\(field) enthält mehr Energie, als bei diesem Gewicht physikalisch plausibel ist."
            )
        }
    }

    private static func nutrient(
        _ identifier: NutrientIdentifier,
        in nutrients: [AnalyzedNutrient]
    ) -> Double? {
        nutrients.first { $0.identifier == identifier }?.value
    }
}

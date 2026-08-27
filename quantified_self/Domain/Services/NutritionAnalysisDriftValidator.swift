import Foundation

enum NutritionAnalysisDriftValidator {
    static let minimumAbsoluteEnergyChangeKilocalories = 100.0
    static let minimumRelativeEnergyChange = 0.20

    static func validate(
        previous: NutritionAnalysisResult?,
        revised: NutritionAnalysisResult
    ) throws {
        guard
            let previous,
            let previousEnergy = energy(in: previous),
            let revisedEnergy = energy(in: revised)
        else { return }
        let absoluteChange = abs(revisedEnergy - previousEnergy)
        let relativeChange = absoluteChange / max(abs(previousEnergy), 1)
        guard
            absoluteChange >= minimumAbsoluteEnergyChangeKilocalories,
            relativeChange >= minimumRelativeEnergyChange
        else { return }

        let explanation = revised.uncertaintySummary?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let previousSummary = previous.uncertaintySummary?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard explanation.count >= 20, explanation != previousSummary else {
            throw NutritionAnalysisError.invalidResult("material calorie change lacks a specific explanation")
        }
    }

    static func hasMaterialEnergyChange(
        previous: NutritionAnalysisResult?,
        revised: NutritionAnalysisResult
    ) -> Bool {
        guard
            let previous,
            let previousEnergy = energy(in: previous),
            let revisedEnergy = energy(in: revised)
        else { return false }
        let absoluteChange = abs(revisedEnergy - previousEnergy)
        let relativeChange = absoluteChange / max(abs(previousEnergy), 1)
        return absoluteChange >= minimumAbsoluteEnergyChangeKilocalories &&
            relativeChange >= minimumRelativeEnergyChange
    }

    private static func energy(in result: NutritionAnalysisResult) -> Double? {
        result.nutrients.first {
            $0.identifier == .energy && $0.unit == .kilocalorie
        }?.value
    }
}

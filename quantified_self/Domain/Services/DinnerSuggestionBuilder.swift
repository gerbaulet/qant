import Foundation

enum DinnerSuggestionBuilder {
    private static let identifiers: [NutrientIdentifier] = [
        .energy, .protein, .fiber, .carbohydrates, .fat,
    ]

    static func makeRequest(
        snapshot: TodayDashboardSnapshot,
        portionCount: Int,
        preferences: DinnerPreferences,
        availableIngredients: String
    ) throws -> DinnerSuggestionRequest {
        guard (1...12).contains(portionCount) else {
            throw DinnerSuggestionError.invalidPortionCount
        }
        let progress = [snapshot.energy] + snapshot.macros + [snapshot.fiber]
        let budgets = identifiers.compactMap { identifier in
            progress.first(where: { $0.id == identifier }).map {
                DinnerNutrientBudget(
                    identifier: identifier,
                    consumed: $0.consumed,
                    target: $0.target,
                    unit: $0.unit
                )
            }
        }
        return DinnerSuggestionRequest(
            portionCount: portionCount,
            budgets: budgets,
            preferences: preferences,
            availableIngredients: availableIngredients,
            hasProvisionalValues: snapshot.hasProvisionalValues
        )
    }

    static func ranked(
        _ suggestions: [SuggestedDinner],
        for budgets: [DinnerNutrientBudget]
    ) -> [SuggestedDinner] {
        suggestions.sorted { lhs, rhs in
            let left = metrics(for: lhs, budgets: budgets)
            let right = metrics(for: rhs, budgets: budgets)

            if right.macroGap > 0, left.macroGap <= right.macroGap * 0.8 { return true }
            if left.macroGap > 0, right.macroGap <= left.macroGap * 0.8 { return false }
            if left.energyWithinTolerance != right.energyWithinTolerance {
                return left.energyWithinTolerance
            }
            if left.energyDeviation != right.energyDeviation {
                return left.energyDeviation < right.energyDeviation
            }
            return left.macroGap < right.macroGap
        }
    }

    private static func metrics(
        for suggestion: SuggestedDinner,
        budgets: [DinnerNutrientBudget]
    ) -> (energyWithinTolerance: Bool, energyDeviation: Double, macroGap: Double) {
        let energyBudget = budgets.first { $0.identifier == .energy }
        let energyRemaining = energyBudget?.remaining
        let energy = suggestion.nutrientValue(.energy) ?? 0
        let energyDeviation: Double
        let withinTolerance: Bool
        if let energyRemaining, energyRemaining > 0 {
            energyDeviation = abs(energy - energyRemaining) / energyRemaining
            withinTolerance = energyDeviation <= 0.1
        } else {
            energyDeviation = energy
            withinTolerance = false
        }

        let weights: [NutrientIdentifier: Double] = [
            .protein: 0.45,
            .fiber: 0.30,
            .carbohydrates: 0.15,
            .fat: 0.10,
        ]
        let macroGap = weights.reduce(0.0) { total, item in
            guard let remaining = budgets.first(where: { $0.identifier == item.key })?.remaining,
                  remaining > 0,
                  let value = suggestion.nutrientValue(item.key) else {
                return total
            }
            return total + item.value * abs(value - remaining) / remaining
        }
        return (withinTolerance, energyDeviation, macroGap)
    }
}

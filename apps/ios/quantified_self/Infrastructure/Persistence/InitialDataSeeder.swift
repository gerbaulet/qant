import Foundation
import SwiftData

@MainActor
enum InitialDataSeeder {
    private struct DefaultGoal {
        let nutrient: NutrientIdentifier
        let value: Double
        let unit: NutrientUnit
    }

    private static let defaultGoals: [DefaultGoal] = [
        DefaultGoal(nutrient: .energy, value: 2_200, unit: .kilocalorie),
        DefaultGoal(nutrient: .protein, value: 130, unit: .gram),
        DefaultGoal(nutrient: .carbohydrates, value: 240, unit: .gram),
        DefaultGoal(nutrient: .fat, value: 75, unit: .gram),
        DefaultGoal(nutrient: .fiber, value: 30, unit: .gram),
    ]

    /// Adds first-run defaults only for nutrients that have no history at all.
    /// Settings will later create new periods instead of mutating these records.
    static func seedGoalsIfNeeded(
        in context: ModelContext,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) throws {
        let existing = try context.fetch(FetchDescriptor<NutritionGoalPeriod>())
        let validFrom = calendar.startOfDay(for: now)
        var inserted = false

        for defaultGoal in defaultGoals where !existing.contains(where: {
            $0.nutrientIdentifierRawValue == defaultGoal.nutrient.rawValue
        }) {
            context.insert(NutritionGoalPeriod(
                createdAt: now,
                modifiedAt: now,
                validFrom: validFrom,
                nutrientIdentifier: defaultGoal.nutrient,
                targetValue: defaultGoal.value,
                unit: defaultGoal.unit
            ))
            inserted = true
        }

        if inserted {
            try context.save()
        }
    }
}

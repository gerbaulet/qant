import Foundation
import Testing
@testable import Quant

@MainActor
struct NutritionPresentationVersionTests {
    @Test("Presentation version changes with persisted meal and goal updates")
    func tracksRelevantModelUpdates() {
        let meal = Meal(timestamp: Date(timeIntervalSince1970: 100))
        let goal = NutritionGoalPeriod(
            validFrom: Date(timeIntervalSince1970: 50),
            nutrientIdentifier: .energy,
            targetValue: 2_000,
            unit: .kilocalorie
        )
        let initial = NutritionPresentationVersion(meals: [meal], goals: [goal])

        meal.modifiedAt = meal.modifiedAt.addingTimeInterval(1)
        let changedMeal = NutritionPresentationVersion(meals: [meal], goals: [goal])
        #expect(changedMeal != initial)

        goal.modifiedAt = goal.modifiedAt.addingTimeInterval(1)
        let changedGoal = NutritionPresentationVersion(meals: [meal], goals: [goal])
        #expect(changedGoal != changedMeal)
    }

    @Test("Presentation version is stable for unchanged collections")
    func remainsStableWithoutChanges() {
        let meal = Meal(timestamp: Date(timeIntervalSince1970: 100))
        let goal = NutritionGoalPeriod(
            validFrom: Date(timeIntervalSince1970: 50),
            nutrientIdentifier: .protein,
            targetValue: 120,
            unit: .gram
        )

        #expect(
            NutritionPresentationVersion(meals: [meal], goals: [goal]) ==
                NutritionPresentationVersion(meals: [meal], goals: [goal])
        )
    }
}

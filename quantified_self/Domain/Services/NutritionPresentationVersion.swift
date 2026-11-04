import Foundation

/// A lightweight value that changes whenever persisted input used by the
/// dashboard, history, or trends changes. Presentation containers use it to
/// retain their last rendered snapshot across tab switches without serving
/// stale data after a model update.
@MainActor
struct NutritionPresentationVersion: Hashable {
    private struct MealVersion: Hashable {
        let id: UUID
        let modifiedAt: Date
        let timestamp: Date
        let userComment: String?
        let mealStateRawValue: String
        let analysisStateRawValue: String
        let activeRevisionID: UUID?
    }

    private struct GoalVersion: Hashable {
        let id: UUID
        let modifiedAt: Date
        let validFrom: Date
        let validUntil: Date?
        let nutrientIdentifierRawValue: String
        let targetValue: Double
        let unitRawValue: String
    }

    private let meals: [MealVersion]
    private let goals: [GoalVersion]

    init(meals: [Meal], goals: [NutritionGoalPeriod]) {
        self.meals = meals.map {
            MealVersion(
                id: $0.id,
                modifiedAt: $0.modifiedAt,
                timestamp: $0.timestamp,
                userComment: $0.userComment,
                mealStateRawValue: $0.mealStateRawValue,
                analysisStateRawValue: $0.analysisStateRawValue,
                activeRevisionID: $0.activeRevisionID
            )
        }
        self.goals = goals.map {
            GoalVersion(
                id: $0.id,
                modifiedAt: $0.modifiedAt,
                validFrom: $0.validFrom,
                validUntil: $0.validUntil,
                nutrientIdentifierRawValue: $0.nutrientIdentifierRawValue,
                targetValue: $0.targetValue,
                unitRawValue: $0.unitRawValue
            )
        }
    }
}

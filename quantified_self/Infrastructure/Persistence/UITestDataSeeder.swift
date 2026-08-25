import Foundation
import SwiftData

#if DEBUG
@MainActor
enum UITestDataSeeder {
    static func seedReviewMealIfRequested(
        arguments: [String],
        in context: ModelContext
    ) throws {
        let wantsConfirmation = arguments.contains("--ui-testing-review-confirmation")
        let wantsClarification = arguments.contains("--ui-testing-review-clarification")
        let wantsFailure = arguments.contains("--ui-testing-review-failure")
        guard wantsConfirmation || wantsClarification || wantsFailure else { return }

        let status: AnalysisState = wantsFailure
            ? .failed
            : wantsClarification ? .needsClarification : .awaitingConfirmation
        let revision = MealAnalysisRevision(
            modelIdentifier: "example/vision-model",
            providerIdentifier: "Example Provider",
            status: status,
            mealName: "Chicken Curry mit Reis",
            estimatedTotalWeightGrams: 440,
            confidence: .medium,
            uncertaintySummary: "Die genaue Menge der Sauce ist auf dem Foto nicht erkennbar.",
            clarificationQuestion: wantsClarification
                ? "Wurde normale oder leichte Kokosmilch verwendet?"
                : nil,
            failureMessage: wantsFailure
                ? "OpenRouter-Fehler 400: Kein Anbieter unterstützt strukturierte Ausgaben."
                : nil,
            components: [
                FoodComponent(sortIndex: 0, name: "Chicken Curry", estimatedWeightGrams: 280),
                FoodComponent(sortIndex: 1, name: "Reis", estimatedWeightGrams: 160),
            ],
            nutrients: [
                nutrient(.energy, 785, .kilocalorie),
                nutrient(.protein, 46, .gram),
                nutrient(.carbohydrates, 92, .gram),
                nutrient(.fat, 25, .gram),
                nutrient(.fiber, 8, .gram),
                nutrient(.sugar, 7, .gram),
                nutrient(.saturatedFat, 11, .gram),
                nutrient(.sodium, 690, .milligram),
            ]
        )
        let meal = Meal(
            timestamp: .now.addingTimeInterval(-1_800),
            userComment: "Große Portion, ungefähr 440 g",
            category: .dinner,
            analysisState: status,
            activeRevisionID: wantsFailure ? nil : revision.id,
            clarificationCount: wantsConfirmation ? 1 : 0,
            analysisRevisions: [revision]
        )
        context.insert(meal)
        try context.save()
    }

    private static func nutrient(
        _ identifier: NutrientIdentifier,
        _ value: Double,
        _ unit: NutrientUnit
    ) -> NutrientValue {
        NutrientValue(
            identifier: identifier,
            value: value,
            unit: unit,
            confidence: .medium,
            provenance: .mixedEstimate
        )
    }
}
#endif

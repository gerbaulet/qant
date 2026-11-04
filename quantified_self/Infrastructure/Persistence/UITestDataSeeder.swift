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
        let wantsConfirmed = arguments.contains("--ui-testing-review-confirmed")
        let wantsClarification = arguments.contains("--ui-testing-review-clarification")
        let wantsFailure = arguments.contains("--ui-testing-review-failure")
        let wantsProgress = arguments.contains("--ui-testing-review-progress")
        let wantsPhoto = arguments.contains("--ui-testing-review-photo")
        let shouldSeed = wantsConfirmation || wantsConfirmed || wantsClarification || wantsFailure ||
            wantsProgress || wantsPhoto
        guard shouldSeed else { return }

        let status: AnalysisState = wantsConfirmed ? .confirmed : wantsProgress ? .analyzing : wantsFailure
            ? .failed
            : wantsClarification ? .needsClarification : .confirmed
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
                component(
                    sortIndex: 0,
                    name: "Chicken Curry",
                    weight: 280,
                    values: [500, 40, 20, 25, 3, 0]
                ),
                component(
                    sortIndex: 1,
                    name: "Reis",
                    weight: 160,
                    values: [285, 6, 72, 0, 5, 0]
                ),
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
            images: wantsPhoto ? [MealImage(
                sortIndex: 0,
                imageStorageKey: "ui-test/missing-image.jpg",
                thumbnailStorageKey: "ui-test/missing-thumbnail.jpg",
                pixelWidth: 1_200,
                pixelHeight: 900
            )] : [],
            analysisRevisions: [revision]
        )
        context.insert(meal)
        try context.save()
        if wantsProgress {
            let store = MealAnalysisProgressStore.shared
            store.begin(meal.id)
            let now = Date.now
            for number in 1...3 {
                _ = store.startCall(
                    for: meal.id,
                    sampleNumber: number,
                    attemptNumber: 1,
                    at: now.addingTimeInterval(-20)
                )
            }
            store.recordStreamEvent(.requestStarted, to: 3, for: meal.id, at: now.addingTimeInterval(-18))
            store.recordStreamEvent(.responseStarted, to: 3, for: meal.id, at: now.addingTimeInterval(-7))
            store.recordStreamEvent(
                .contentDelta(
                    """
                    {"mealName":"Chicken Curry mit Reis","estimatedTotalWeightGrams":440,
                    "confidence":"medium","uncertaintySummary":"Die genaue Menge der Sauce",
                    "components":[{"name":"Chicken Curry","estimatedWeightGrams":280}],
                    "nutrients":[{"identifier":"energy","value":785,"unit":"kcal"}]}
                    """
                ),
                to: 3,
                for: meal.id,
                at: now.addingTimeInterval(-5)
            )
            store.finishCall(AnalysisCallSummary(
                callNumber: 1, sampleNumber: 1, attemptNumber: 1, status: .succeeded,
                modelIdentifier: "example/vision-model", providerIdentifier: "Example Provider",
                energyKilocalories: 785, errorMessage: nil
            ), for: meal.id)
            store.finishCall(AnalysisCallSummary(
                callNumber: 2, sampleNumber: 2, attemptNumber: 1, status: .failed,
                modelIdentifier: nil, providerIdentifier: nil, energyKilocalories: nil,
                errorMessage: "Die Ernährungsanalyse konnte nicht gelesen werden."
            ), for: meal.id)
        }
    }

    private static func component(
        sortIndex: Int,
        name: String,
        weight: Double,
        values: [Double]
    ) -> FoodComponent {
        let identifiers: [NutrientIdentifier] = [
            .energy,
            .protein,
            .carbohydrates,
            .fat,
            .fiber,
            .alcohol,
        ]
        return FoodComponent(
            sortIndex: sortIndex,
            name: name,
            estimatedWeightGrams: weight,
            nutrients: zip(identifiers, values).map { identifier, value in
                nutrient(
                    identifier,
                    value,
                    NutritionAnalysisValidator.expectedUnit(for: identifier)
                )
            }
        )
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

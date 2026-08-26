import Foundation
import Testing
@testable import quantified_self

struct DinnerSuggestionBuilderTests {
    @Test("Request uses remaining confirmed and provisional dashboard values")
    func makesBudgetRequest() throws {
        let snapshot = makeSnapshot(energyConsumed: 1_700, provisional: true)
        let preferences = DinnerPreferences(dietaryStyle: .vegetarian)

        let request = try DinnerSuggestionBuilder.makeRequest(
            snapshot: snapshot,
            portionCount: 4,
            preferences: preferences,
            availableIngredients: "Brokkoli"
        )

        #expect(request.portionCount == 4)
        #expect(request.hasProvisionalValues)
        #expect(request.budgets.first(where: { $0.identifier == .energy })?.remaining == 500)
        #expect(request.budgets.first(where: { $0.identifier == .protein })?.remaining == 50)
        #expect(request.availableIngredients == "Brokkoli")
    }

    @Test("Exceeded targets expose zero remaining budget without inventing negative demand")
    func clampsExceededBudget() throws {
        let request = try DinnerSuggestionBuilder.makeRequest(
            snapshot: makeSnapshot(energyConsumed: 2_300),
            portionCount: 1,
            preferences: DinnerPreferences(),
            availableIngredients: ""
        )
        let energy = try #require(request.budgets.first { $0.identifier == .energy })
        #expect(energy.remaining == 0)
        #expect(energy.isExceeded)
    }

    @Test(arguments: [0, 13])
    func rejectsInvalidPortionCount(_ portionCount: Int) {
        #expect(throws: DinnerSuggestionError.invalidPortionCount) {
            try DinnerSuggestionBuilder.makeRequest(
                snapshot: makeSnapshot(),
                portionCount: portionCount,
                preferences: DinnerPreferences(),
                availableIngredients: ""
            )
        }
    }

    @Test("A substantially better macro fit may outrank the calorie tolerance")
    func macroBenefitCanOutrankCalories() {
        let budgets = [
            budget(.energy, consumed: 1_600, target: 2_200, unit: .kilocalorie),
            budget(.protein, consumed: 80, target: 130),
            budget(.fiber, consumed: 15, target: 30),
            budget(.carbohydrates, consumed: 180, target: 240),
            budget(.fat, consumed: 55, target: 75),
        ]
        let calorieFit = dinner("Kaloriennah", energy: 600, protein: 10, fiber: 2, carbohydrates: 20, fat: 5)
        let macroFit = dinner("Makronah", energy: 750, protein: 50, fiber: 15, carbohydrates: 60, fat: 20)

        let ranked = DinnerSuggestionBuilder.ranked([calorieFit, macroFit], for: budgets)

        #expect(ranked.first?.name == "Makronah")
    }

    @Test("The ten percent calorie boundary still counts as fitting")
    func calorieToleranceBoundary() {
        let budgets = [budget(.energy, consumed: 1_600, target: 2_200, unit: .kilocalorie)]
        let boundary = dinner("Grenzwert", energy: 660, protein: 0, fiber: 0, carbohydrates: 0, fat: 0)
        let outside = dinner("Außerhalb", energy: 700, protein: 0, fiber: 0, carbohydrates: 0, fat: 0)

        #expect(DinnerSuggestionBuilder.ranked([outside, boundary], for: budgets).first?.name == "Grenzwert")
    }

    private func makeSnapshot(
        energyConsumed: Double = 1_600,
        provisional: Bool = false
    ) -> TodayDashboardSnapshot {
        TodayDashboardSnapshot(
            date: .now,
            energy: NutrientProgress(id: .energy, consumed: energyConsumed, target: 2_200, unit: .kilocalorie),
            weeklyEnergy: NutrientProgress(id: .energy, consumed: energyConsumed, target: 15_400, unit: .kilocalorie),
            macros: [
                NutrientProgress(id: .protein, consumed: 80, target: 130, unit: .gram),
                NutrientProgress(id: .carbohydrates, consumed: 180, target: 240, unit: .gram),
                NutrientProgress(id: .fat, consumed: 55, target: 75, unit: .gram),
            ],
            fiber: NutrientProgress(id: .fiber, consumed: 15, target: 30, unit: .gram),
            meals: [],
            hasProvisionalValues: provisional
        )
    }

    private func budget(
        _ identifier: NutrientIdentifier,
        consumed: Double,
        target: Double,
        unit: NutrientUnit = .gram
    ) -> DinnerNutrientBudget {
        DinnerNutrientBudget(identifier: identifier, consumed: consumed, target: target, unit: unit)
    }

    private func dinner(
        _ name: String,
        energy: Double,
        protein: Double,
        fiber: Double,
        carbohydrates: Double,
        fat: Double
    ) -> SuggestedDinner {
        SuggestedDinner(
            name: name,
            fitSummary: "Passt zum Budget.",
            ingredients: [SuggestedIngredient(name: "Gemüse", amount: 200, unit: "g")],
            nutrients: [
                SuggestedNutrient(identifier: .energy, valuePerServing: energy, unit: .kilocalorie),
                SuggestedNutrient(identifier: .protein, valuePerServing: protein, unit: .gram),
                SuggestedNutrient(identifier: .fiber, valuePerServing: fiber, unit: .gram),
                SuggestedNutrient(identifier: .carbohydrates, valuePerServing: carbohydrates, unit: .gram),
                SuggestedNutrient(identifier: .fat, valuePerServing: fat, unit: .gram),
            ]
        )
    }
}

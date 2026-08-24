import Foundation
import Testing
@testable import quantified_self

struct NutritionHintBuilderTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test("No hints appear without logged meals")
    func emptyDay() {
        let hints = NutritionHintBuilder.makeHints(
            for: snapshot(mealCount: 0, energy: 0, protein: 0, fiber: 0),
            at: date(hour: 20),
            calendar: calendar
        )

        #expect(hints.isEmpty)
    }

    @Test("Low macro hints wait until evening")
    func macroTiming() {
        let current = snapshot(mealCount: 2, energy: 1_000, protein: 40, fiber: 8)

        let afternoon = NutritionHintBuilder.makeHints(
            for: current,
            at: date(hour: 15),
            calendar: calendar
        )
        let evening = NutritionHintBuilder.makeHints(
            for: current,
            at: date(hour: 20),
            calendar: calendar
        )

        #expect(afternoon.isEmpty)
        #expect(evening.map(\.kind) == [.proteinLow, .fiberLow])
    }

    @Test("Actionable evening deficits outrank calorie target proximity")
    func actionableDeficitPriority() {
        let hints = NutritionHintBuilder.makeHints(
            for: snapshot(mealCount: 3, energy: 2_050, protein: 40, fiber: 8),
            at: date(hour: 20),
            calendar: calendar
        )

        #expect(hints.count == 2)
        #expect(hints.map(\.kind) == [.proteinLow, .fiberLow])
    }

    @Test("A calorie overage needs a clear ten-percent margin")
    func calorieTargetExceeded() {
        let belowThreshold = NutritionHintBuilder.makeHints(
            for: snapshot(mealCount: 3, energy: 2_419, protein: 100, fiber: 25),
            at: date(hour: 15),
            calendar: calendar
        )
        let atThreshold = NutritionHintBuilder.makeHints(
            for: snapshot(mealCount: 3, energy: 2_420, protein: 100, fiber: 25),
            at: date(hour: 15),
            calendar: calendar
        )

        #expect(!belowThreshold.map(\.kind).contains(.calorieTargetExceeded))
        #expect(atThreshold.map(\.kind) == [.calorieTargetExceeded])
    }

    @Test("Reached protein and fiber targets produce positive hints")
    func reachedTargets() {
        let proteinHints = NutritionHintBuilder.makeHints(
            for: snapshot(mealCount: 2, energy: 1_000, protein: 130, fiber: 25),
            at: date(hour: 15),
            calendar: calendar
        )
        let fiberHints = NutritionHintBuilder.makeHints(
            for: snapshot(mealCount: 2, energy: 1_000, protein: 100, fiber: 30),
            at: date(hour: 15),
            calendar: calendar
        )

        #expect(proteinHints.map(\.kind) == [.proteinTargetReached])
        #expect(fiberHints.map(\.kind) == [.fiberTargetReached])
    }

    @Test("Low carbohydrates wait until evening")
    func carbohydratesTiming() {
        let current = snapshot(
            mealCount: 2,
            energy: 1_000,
            protein: 100,
            carbohydrates: 100,
            fat: 70,
            fiber: 25
        )

        let afternoon = NutritionHintBuilder.makeHints(
            for: current,
            at: date(hour: 15),
            calendar: calendar
        )
        let evening = NutritionHintBuilder.makeHints(
            for: current,
            at: date(hour: 20),
            calendar: calendar
        )

        #expect(afternoon.isEmpty)
        #expect(evening.map(\.kind) == [.carbohydratesLow])
    }

    @Test("A high-fat hint needs a fifteen-percent margin")
    func fatHigh() {
        let belowThreshold = NutritionHintBuilder.makeHints(
            for: snapshot(mealCount: 2, energy: 1_000, protein: 100, fat: 86.24, fiber: 25),
            at: date(hour: 15),
            calendar: calendar
        )
        let atThreshold = NutritionHintBuilder.makeHints(
            for: snapshot(mealCount: 2, energy: 1_000, protein: 100, fat: 86.25, fiber: 25),
            at: date(hour: 15),
            calendar: calendar
        )

        #expect(!belowThreshold.map(\.kind).contains(.fatHigh))
        #expect(atThreshold.map(\.kind) == [.fatHigh])
    }

    @Test("Only the two highest-scoring hints are returned")
    func importanceRanking() {
        let hints = NutritionHintBuilder.makeHints(
            for: snapshot(
                mealCount: 3,
                energy: 1_500,
                protein: 130,
                carbohydrates: 200,
                fat: 90,
                fiber: 30
            ),
            at: date(hour: 15),
            calendar: calendar
        )

        #expect(hints.map(\.kind) == [.fatHigh, .proteinTargetReached])
        #expect(hints.count == 2)
        #expect(hints[0].importanceScore > hints[1].importanceScore)
    }

    private func snapshot(
        mealCount: Int,
        energy: Double,
        protein: Double,
        carbohydrates: Double = 100,
        fat: Double = 40,
        fiber: Double
    ) -> TodayDashboardSnapshot {
        TodayDashboardSnapshot(
            date: date(hour: 20),
            energy: NutrientProgress(id: .energy, consumed: energy, target: 2_200, unit: .kilocalorie),
            weeklyEnergy: NutrientProgress(id: .energy, consumed: energy, target: 15_400, unit: .kilocalorie),
            macros: [
                NutrientProgress(id: .protein, consumed: protein, target: 130, unit: .gram),
                NutrientProgress(id: .carbohydrates, consumed: carbohydrates, target: 240, unit: .gram),
                NutrientProgress(id: .fat, consumed: fat, target: 75, unit: .gram),
            ],
            fiber: NutrientProgress(id: .fiber, consumed: fiber, target: 30, unit: .gram),
            meals: (0..<mealCount).map { index in
                TodayMealSummary(
                    id: UUID(),
                    timestamp: date(hour: 12 + index),
                    name: "Mahlzeit",
                    energyKilocalories: 400,
                    analysisState: .confirmed,
                    isProvisional: false,
                    thumbnailStorageKey: nil
                )
            },
            hasProvisionalValues: false
        )
    }

    private func date(hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 23, hour: hour))!
    }
}

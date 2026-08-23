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

    @Test("Near-target calories take priority and hints stay compact")
    func caloriePriority() {
        let hints = NutritionHintBuilder.makeHints(
            for: snapshot(mealCount: 3, energy: 2_050, protein: 40, fiber: 8),
            at: date(hour: 20),
            calendar: calendar
        )

        #expect(hints.count == 2)
        #expect(hints.first?.kind == .calorieTargetNear)
        #expect(hints.last?.kind == .proteinLow)
    }

    private func snapshot(
        mealCount: Int,
        energy: Double,
        protein: Double,
        fiber: Double
    ) -> TodayDashboardSnapshot {
        TodayDashboardSnapshot(
            date: date(hour: 20),
            energy: NutrientProgress(id: .energy, consumed: energy, target: 2_200, unit: .kilocalorie),
            weeklyEnergy: NutrientProgress(id: .energy, consumed: energy, target: 15_400, unit: .kilocalorie),
            macros: [
                NutrientProgress(id: .protein, consumed: protein, target: 130, unit: .gram),
                NutrientProgress(id: .carbohydrates, consumed: 100, target: 240, unit: .gram),
                NutrientProgress(id: .fat, consumed: 40, target: 75, unit: .gram),
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

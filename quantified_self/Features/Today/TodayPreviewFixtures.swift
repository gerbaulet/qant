#if DEBUG
import Foundation

extension TodayDashboardSnapshot {
    static var preview: TodayDashboardSnapshot {
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 23,
            hour: 18
        ))!

        return TodayDashboardSnapshot(
            date: date,
            energy: NutrientProgress(
                id: .energy,
                consumed: 1_640,
                target: 2_200,
                unit: .kilocalorie
            ),
            macros: [
                NutrientProgress(id: .protein, consumed: 92, target: 130, unit: .gram),
                NutrientProgress(id: .carbohydrates, consumed: 174, target: 240, unit: .gram),
                NutrientProgress(id: .fat, consumed: 61, target: 75, unit: .gram),
            ],
            meals: [
                TodayMealSummary(
                    id: UUID(),
                    timestamp: date.addingTimeInterval(-30 * 60),
                    name: nil,
                    energyKilocalories: nil,
                    analysisState: .analyzing,
                    isProvisional: false,
                    thumbnailStorageKey: nil
                ),
                TodayMealSummary(
                    id: UUID(),
                    timestamp: date.addingTimeInterval(-4 * 60 * 60),
                    name: "Chicken Curry mit Reis",
                    energyKilocalories: 785,
                    analysisState: .awaitingConfirmation,
                    isProvisional: true,
                    thumbnailStorageKey: "preview/lunch-thumb.heic"
                ),
                TodayMealSummary(
                    id: UUID(),
                    timestamp: date.addingTimeInterval(-10 * 60 * 60),
                    name: "Griechischer Joghurt mit Beeren",
                    energyKilocalories: 430,
                    analysisState: .confirmed,
                    isProvisional: false,
                    thumbnailStorageKey: "preview/breakfast-thumb.heic"
                ),
            ],
            hasProvisionalValues: true
        )
    }
}
#endif

import Foundation

enum IntakeForecastDifference: Equatable, Sendable {
    case equal
    case mealAwareLower(Double)
    case mealAwareHigher(Double)
}

struct IntakeForecastComparison: Sendable {
    let actualPoints: [CumulativeNutritionTrendPoint]
    let historicalRemainderPoints: [CumulativeNutritionTrendPoint]
    let mealAwarePoints: [CumulativeNutritionTrendPoint]
    let historicalDayCount: Int
    let actualHasProvisionalValues: Bool
    let forecastHasProvisionalValues: Bool

    var actualEnergyKilocalories: Double {
        actualPoints.last?.value ?? 0
    }

    var historicalRemainderEnergyKilocalories: Double? {
        historicalRemainderPoints.last?.value
    }

    var mealAwareEnergyKilocalories: Double? {
        mealAwarePoints.last?.value
    }

    var difference: IntakeForecastDifference? {
        guard let historicalRemainderEnergyKilocalories,
              let mealAwareEnergyKilocalories else {
            return nil
        }
        let difference = mealAwareEnergyKilocalories - historicalRemainderEnergyKilocalories
        if abs(difference) < 0.5 {
            return .equal
        }
        if difference < 0 {
            return .mealAwareLower(abs(difference))
        }
        return .mealAwareHigher(difference)
    }
}

@MainActor
enum IntakeForecastComparisonBuilder {
    static func makeComparison(
        for date: Date,
        meals: [Meal],
        calendar: Calendar
    ) -> IntakeForecastComparison {
        let historicalRemainder = NutritionTrendsBuilder.makeDailyCumulativeTrend(
            for: date,
            nutrient: .energy,
            meals: meals,
            calendar: calendar,
            forecastStrategy: .historicalRemainder
        )
        let mealAware = NutritionTrendsBuilder.makeDailyCumulativeTrend(
            for: date,
            nutrient: .energy,
            meals: meals,
            calendar: calendar,
            forecastStrategy: .mealAware
        )
        let activeRevisions = ActiveMealRevisionSnapshot(meals: meals)
        let dayInterval = calendar.dateInterval(of: .day, for: date)
        let actualHasProvisionalValues = dayInterval.map { interval in
            meals.contains { meal in
                guard meal.mealState != .archived,
                      interval.contains(meal.timestamp) else {
                    return false
                }
                return activeRevisions.revision(for: meal)?.status
                    .isProvisionalNutritionEstimate == true
            }
        } ?? false

        return IntakeForecastComparison(
            actualPoints: historicalRemainder.actualPoints,
            historicalRemainderPoints: historicalRemainder.forecastPoints,
            mealAwarePoints: mealAware.forecastPoints,
            historicalDayCount: historicalRemainder.forecastDayCount,
            actualHasProvisionalValues: actualHasProvisionalValues,
            forecastHasProvisionalValues: historicalRemainder.hasProvisionalValues ||
                mealAware.hasProvisionalValues
        )
    }
}

import Foundation

struct WeeklyNutritionSummary: Sendable {
    let interval: DateInterval
    let energyKilocalories: Double
    let energyTargetKilocalories: Double?
    let trackedDayCount: Int
    let averageEnergyKilocalories: Double?
    let averageProteinGrams: Double?
    let averageCarbohydratesGrams: Double?
    let averageFatGrams: Double?
    let daysWithinEnergyTarget: Int
    let daysAboveEnergyTarget: Int
    let previousWeekAverageEnergyChangePercent: Double?
}

/// Builds stable historical statistics from confirmed revisions only. Missing
/// days remain missing instead of being interpreted as zero intake.
@MainActor
enum WeeklyNutritionSummaryBuilder {
    static func makeSummary(
        containing date: Date,
        meals: [Meal],
        goals: [NutritionGoalPeriod],
        calendar: Calendar
    ) -> WeeklyNutritionSummary? {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: date),
              let previousDate = calendar.date(byAdding: .weekOfYear, value: -1, to: interval.start),
              let previousInterval = calendar.dateInterval(of: .weekOfYear, for: previousDate) else {
            return nil
        }

        let current = aggregate(interval: interval, meals: meals, goals: goals, calendar: calendar)
        let previous = aggregate(interval: previousInterval, meals: meals, goals: goals, calendar: calendar)
        let change: Double?
        if let currentAverage = current.averageEnergy,
           let previousAverage = previous.averageEnergy,
           previousAverage > 0 {
            change = ((currentAverage - previousAverage) / previousAverage) * 100
        } else {
            change = nil
        }

        return WeeklyNutritionSummary(
            interval: interval,
            energyKilocalories: current.energy,
            energyTargetKilocalories: current.weeklyTarget,
            trackedDayCount: current.trackedDays,
            averageEnergyKilocalories: current.averageEnergy,
            averageProteinGrams: current.averageProtein,
            averageCarbohydratesGrams: current.averageCarbohydrates,
            averageFatGrams: current.averageFat,
            daysWithinEnergyTarget: current.daysWithinTarget,
            daysAboveEnergyTarget: current.daysAboveTarget,
            previousWeekAverageEnergyChangePercent: change
        )
    }

    private struct Aggregate {
        var energy = 0.0
        var protein = 0.0
        var carbohydrates = 0.0
        var fat = 0.0
        var trackedDays = 0
        var daysWithinTarget = 0
        var daysAboveTarget = 0
        var weeklyTarget: Double?

        var averageEnergy: Double? { average(energy) }
        var averageProtein: Double? { average(protein) }
        var averageCarbohydrates: Double? { average(carbohydrates) }
        var averageFat: Double? { average(fat) }

        private func average(_ value: Double) -> Double? {
            trackedDays > 0 ? value / Double(trackedDays) : nil
        }
    }

    private static func aggregate(
        interval: DateInterval,
        meals: [Meal],
        goals: [NutritionGoalPeriod],
        calendar: Calendar
    ) -> Aggregate {
        var result = Aggregate()
        result.weeklyTarget = try? GoalHistory.weeklyTarget(
            for: .energy,
            containing: interval.start,
            calendar: calendar,
            periods: goals
        )

        var cursor = interval.start
        while cursor < interval.end,
              let day = calendar.dateInterval(of: .day, for: cursor) {
            let revisions = meals.compactMap { meal -> MealAnalysisRevision? in
                guard meal.mealState != .archived,
                      meal.timestamp >= day.start,
                      meal.timestamp < day.end,
                      let revision = meal.activeRevision,
                      revision.status == .confirmed else {
                    return nil
                }
                return revision
            }

            if !revisions.isEmpty {
                result.trackedDays += 1
                let energy = nutrientTotal(.energy, unit: .kilocalorie, revisions: revisions)
                result.energy += energy
                result.protein += nutrientTotal(.protein, unit: .gram, revisions: revisions)
                result.carbohydrates += nutrientTotal(.carbohydrates, unit: .gram, revisions: revisions)
                result.fat += nutrientTotal(.fat, unit: .gram, revisions: revisions)

                if let target = GoalHistory.goal(for: .energy, at: day.start, in: goals)?.targetValue {
                    if energy <= target {
                        result.daysWithinTarget += 1
                    } else {
                        result.daysAboveTarget += 1
                    }
                }
            }

            guard let next = calendar.date(byAdding: .day, value: 1, to: day.start), next > cursor else {
                break
            }
            cursor = next
        }
        return result
    }

    private static func nutrientTotal(
        _ identifier: NutrientIdentifier,
        unit: NutrientUnit,
        revisions: [MealAnalysisRevision]
    ) -> Double {
        revisions
            .flatMap(\.nutrients)
            .filter { $0.identifierRawValue == identifier.rawValue && $0.unitRawValue == unit.rawValue }
            .reduce(0) { $0 + $1.value }
    }
}

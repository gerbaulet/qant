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
    let averageFiberGrams: Double?
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
        let portionMultipliers = PortionMultiplierSnapshot()
        let activeRevisions = ActiveMealRevisionSnapshot(meals: meals)

        let current = aggregate(
            interval: interval,
            meals: meals,
            goals: goals,
            calendar: calendar,
            portionMultipliers: portionMultipliers,
            activeRevisions: activeRevisions
        )
        let previous = aggregate(
            interval: previousInterval,
            meals: meals,
            goals: goals,
            calendar: calendar,
            portionMultipliers: portionMultipliers,
            activeRevisions: activeRevisions
        )
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
            averageFiberGrams: current.averageFiber,
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
        var fiber = 0.0
        var trackedDays = 0
        var daysWithinTarget = 0
        var daysAboveTarget = 0
        var weeklyTarget: Double?

        var averageEnergy: Double? { average(energy) }
        var averageProtein: Double? { average(protein) }
        var averageCarbohydrates: Double? { average(carbohydrates) }
        var averageFat: Double? { average(fat) }
        var averageFiber: Double? { average(fiber) }

        private func average(_ value: Double) -> Double? {
            trackedDays > 0 ? value / Double(trackedDays) : nil
        }
    }

    private static func aggregate(
        interval: DateInterval,
        meals: [Meal],
        goals: [NutritionGoalPeriod],
        calendar: Calendar,
        portionMultipliers: PortionMultiplierSnapshot,
        activeRevisions: ActiveMealRevisionSnapshot
    ) -> Aggregate {
        var result = Aggregate()
        result.weeklyTarget = try? GoalHistory.weeklyTarget(
            for: .energy,
            containing: interval.start,
            calendar: calendar,
            periods: goals
        )

        let relevantMeals = meals.filter { meal in
            meal.mealState != .archived &&
                meal.timestamp >= interval.start &&
                meal.timestamp < interval.end &&
                activeRevisions.revision(for: meal)?.status == .confirmed
        }
        let mealsByDay = Dictionary(grouping: relevantMeals) {
            calendar.startOfDay(for: $0.timestamp)
        }

        for dayStart in mealsByDay.keys.sorted() {
            let revisions = mealsByDay[dayStart, default: []].compactMap {
                activeRevisions.revision(for: $0)
            }
            if !revisions.isEmpty {
                result.trackedDays += 1
                let totals = nutrientTotals(
                    revisions: revisions,
                    portionMultipliers: portionMultipliers
                )
                let energy = totals[.energy, default: 0]
                result.energy += energy
                result.protein += totals[.protein, default: 0]
                result.carbohydrates += totals[.carbohydrates, default: 0]
                result.fat += totals[.fat, default: 0]
                result.fiber += totals[.fiber, default: 0]

                if let target = GoalHistory.goal(for: .energy, at: dayStart, in: goals)?.targetValue {
                    if energy <= target {
                        result.daysWithinTarget += 1
                    } else {
                        result.daysAboveTarget += 1
                    }
                }
            }
        }
        return result
    }

    private static func nutrientTotals(
        revisions: [MealAnalysisRevision],
        portionMultipliers: PortionMultiplierSnapshot
    ) -> [NutrientIdentifier: Double] {
        var totals: [NutrientIdentifier: Double] = [:]
        for revision in revisions {
            for nutrient in revision.nutrients {
                guard let identifier = nutrient.knownIdentifier else { continue }
                totals[identifier, default: 0] += portionMultipliers.scaled(nutrient, for: revision)
            }
        }
        return totals
    }
}

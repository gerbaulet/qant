import Foundation

enum NutritionTrendRange: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month
    case year

    var id: Self { self }
}

struct NutritionTrendPoint: Identifiable, Sendable {
    let date: Date
    let value: Double

    var id: Date { date }
}

struct MonthlyNutritionSummary: Sendable {
    let interval: DateInterval
    let calendarDayCount: Int
    let trackedDayCount: Int
    let totals: [NutrientIdentifier: Double]
    let daysAboveEnergyTarget: Int
    let daysAtOrBelowEnergyTarget: Int

    func average(for nutrient: NutrientIdentifier) -> Double? {
        guard trackedDayCount > 0, let total = totals[nutrient] else { return nil }
        return total / Double(trackedDayCount)
    }
}

struct MonthlyNutritionComparison: Sendable {
    let current: MonthlyNutritionSummary
    let previous: MonthlyNutritionSummary

    func percentChange(for nutrient: NutrientIdentifier) -> Double? {
        guard let currentValue = current.average(for: nutrient),
              let previousValue = previous.average(for: nutrient),
              previousValue > 0 else { return nil }
        return (currentValue - previousValue) / previousValue * 100
    }
}

struct NutritionTrendsSnapshot: Sendable {
    let range: NutritionTrendRange
    let nutrient: NutrientIdentifier
    let interval: DateInterval
    let points: [NutritionTrendPoint]
    let monthlyComparison: MonthlyNutritionComparison
}

@MainActor
enum NutritionTrendsBuilder {
    private static let comparedNutrients: [NutrientIdentifier] = [
        .energy, .protein, .carbohydrates, .fat, .fiber,
    ]

    static func makeSnapshot(
        for date: Date,
        range: NutritionTrendRange,
        nutrient: NutrientIdentifier,
        meals: [Meal],
        goals: [NutritionGoalPeriod],
        calendar: Calendar
    ) -> NutritionTrendsSnapshot {
        let interval = dateInterval(for: date, range: range, calendar: calendar)
            ?? DateInterval(start: date, duration: 1)
        let totals = dailyTotals(meals: meals, within: interval, calendar: calendar)
        let points = totals.compactMap { total -> NutritionTrendPoint? in
            guard let value = total.values[nutrient] else { return nil }
            return NutritionTrendPoint(date: total.date, value: value)
        }
        .sorted { $0.date < $1.date }

        return NutritionTrendsSnapshot(
            range: range,
            nutrient: nutrient,
            interval: interval,
            points: points,
            monthlyComparison: makeMonthlyComparison(
                for: date,
                meals: meals,
                goals: goals,
                calendar: calendar
            )
        )
    }

    private static func makeMonthlyComparison(
        for date: Date,
        meals: [Meal],
        goals: [NutritionGoalPeriod],
        calendar: Calendar
    ) -> MonthlyNutritionComparison {
        guard let currentMonth = calendar.dateInterval(of: .month, for: date),
              let previousReference = calendar.date(byAdding: .day, value: -1, to: currentMonth.start),
              let previousMonth = calendar.dateInterval(of: .month, for: previousReference),
              let dayAfterReference = calendar.date(
                byAdding: .day,
                value: 1,
                to: calendar.startOfDay(for: date)
              ) else {
            let fallback = DateInterval(start: date, duration: 1)
            let empty = MonthlyNutritionSummary(
                interval: fallback,
                calendarDayCount: 1,
                trackedDayCount: 0,
                totals: [:],
                daysAboveEnergyTarget: 0,
                daysAtOrBelowEnergyTarget: 0
            )
            return MonthlyNutritionComparison(current: empty, previous: empty)
        }

        let currentEnd = min(dayAfterReference, currentMonth.end)
        let elapsedDays = max(
            1,
            calendar.dateComponents([.day], from: currentMonth.start, to: currentEnd).day ?? 1
        )
        let previousEnd = min(
            calendar.date(byAdding: .day, value: elapsedDays, to: previousMonth.start)
                ?? previousMonth.end,
            previousMonth.end
        )
        let currentInterval = DateInterval(start: currentMonth.start, end: currentEnd)
        let previousInterval = DateInterval(start: previousMonth.start, end: previousEnd)

        return MonthlyNutritionComparison(
            current: summary(
                for: currentInterval,
                calendarDayCount: elapsedDays,
                meals: meals,
                goals: goals,
                calendar: calendar
            ),
            previous: summary(
                for: previousInterval,
                calendarDayCount: calendar.dateComponents(
                    [.day],
                    from: previousInterval.start,
                    to: previousInterval.end
                ).day ?? elapsedDays,
                meals: meals,
                goals: goals,
                calendar: calendar
            )
        )
    }

    private static func summary(
        for interval: DateInterval,
        calendarDayCount: Int,
        meals: [Meal],
        goals: [NutritionGoalPeriod],
        calendar: Calendar
    ) -> MonthlyNutritionSummary {
        let days = dailyTotals(meals: meals, within: interval, calendar: calendar)
        var totals: [NutrientIdentifier: Double] = [:]
        for day in days {
            for nutrient in comparedNutrients {
                totals[nutrient, default: 0] += day.values[nutrient, default: 0]
            }
        }

        var above = 0
        var atOrBelow = 0
        for day in days {
            guard let energy = day.values[.energy],
                  let target = GoalHistory.goal(for: .energy, at: day.date, in: goals)?.targetValue else {
                continue
            }
            if energy > target { above += 1 } else { atOrBelow += 1 }
        }

        return MonthlyNutritionSummary(
            interval: interval,
            calendarDayCount: calendarDayCount,
            trackedDayCount: days.count,
            totals: totals,
            daysAboveEnergyTarget: above,
            daysAtOrBelowEnergyTarget: atOrBelow
        )
    }

    private struct DailyTotal {
        let date: Date
        let values: [NutrientIdentifier: Double]
    }

    private static func dailyTotals(
        meals: [Meal],
        within interval: DateInterval,
        calendar: Calendar
    ) -> [DailyTotal] {
        let confirmedMeals = meals.filter { meal in
            meal.mealState != .archived &&
                meal.timestamp >= interval.start &&
                meal.timestamp < interval.end &&
                meal.activeRevision?.status == .confirmed
        }
        let grouped = Dictionary(grouping: confirmedMeals) {
            calendar.startOfDay(for: $0.timestamp)
        }
        return grouped.map { date, meals in
            var values: [NutrientIdentifier: Double] = [:]
            for meal in meals {
                guard let revision = meal.activeRevision else { continue }
                for nutrient in revision.nutrients {
                    guard let identifier = nutrient.knownIdentifier,
                          comparedNutrients.contains(identifier) else { continue }
                    values[identifier, default: 0] += nutrient.value
                }
            }
            return DailyTotal(date: date, values: values)
        }
    }

    private static func dateInterval(
        for date: Date,
        range: NutritionTrendRange,
        calendar: Calendar
    ) -> DateInterval? {
        switch range {
        case .day: calendar.dateInterval(of: .day, for: date)
        case .week: calendar.dateInterval(of: .weekOfYear, for: date)
        case .month: calendar.dateInterval(of: .month, for: date)
        case .year: calendar.dateInterval(of: .year, for: date)
        }
    }
}

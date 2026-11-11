import Foundation

enum NutritionTrendRange: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month
    case year

    var id: Self { self }

    var dayCount: Int {
        switch self {
        case .day: 1
        case .week: 7
        case .month: 30
        case .year: 365
        }
    }
}

struct NutritionTrendPoint: Identifiable, Sendable {
    let date: Date
    let value: Double
    let isForecast: Bool
    let isProvisional: Bool

    init(date: Date, value: Double, isForecast: Bool = false, isProvisional: Bool = false) {
        self.date = date
        self.value = value
        self.isForecast = isForecast
        self.isProvisional = isProvisional
    }

    var id: Date { date }
}

struct CumulativeNutritionTrendPoint: Identifiable, Sendable {
    let hour: Double
    let value: Double

    var id: Double { hour }
}

struct DailyCumulativeNutritionTrend: Sendable {
    let actualPoints: [CumulativeNutritionTrendPoint]
    let averagePoints: [CumulativeNutritionTrendPoint]
    let forecastPoints: [CumulativeNutritionTrendPoint]
    let hasActualData: Bool
    let averageDayCount: Int
    let forecastDayCount: Int
    let hasProvisionalValues: Bool
}

struct NutritionPeriodSummary: Sendable {
    let interval: DateInterval
    let calendarDayCount: Int
    let trackedDayCount: Int
    let totals: [NutrientIdentifier: Double]
    let daysAboveEnergyTarget: Int
    let daysAtOrBelowEnergyTarget: Int
    let hasProvisionalValues: Bool

    func average(for nutrient: NutrientIdentifier) -> Double? {
        guard trackedDayCount > 0, let total = totals[nutrient] else { return nil }
        return total / Double(trackedDayCount)
    }
}

struct NutritionPeriodComparison: Sendable {
    let current: NutritionPeriodSummary
    let previous: NutritionPeriodSummary

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
    let dailyCumulativeTrend: DailyCumulativeNutritionTrend
    let periodComparison: NutritionPeriodComparison
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
        let portionMultipliers = PortionMultiplierSnapshot()
        let activeRevisions = ActiveMealRevisionSnapshot(meals: meals)
        let interval = dateInterval(for: date, range: range, calendar: calendar)
            ?? DateInterval(start: date, duration: 1)
        let dailyCumulativeTrend = makeDailyCumulativeTrend(
            for: date,
            nutrient: nutrient,
            meals: meals,
            calendar: calendar,
            portionMultipliers: portionMultipliers,
            activeRevisions: activeRevisions
        )
        let today = calendar.startOfDay(for: date)
        let comparisonStart = calendar.date(
            byAdding: .day,
            value: -(range.dayCount * 2),
            to: today
        ) ?? interval.start
        let totalsInterval = DateInterval(
            start: min(comparisonStart, interval.start),
            end: interval.end
        )
        let allTotals = dailyTotals(
            meals: meals,
            within: totalsInterval,
            calendar: calendar,
            portionMultipliers: portionMultipliers,
            activeRevisions: activeRevisions
        )
        let totals = allTotals.filter {
            $0.date >= interval.start && $0.date < interval.end
        }
        var points = totals.compactMap { total -> NutritionTrendPoint? in
            guard let value = total.values[nutrient] else { return nil }
            return NutritionTrendPoint(
                date: total.date,
                value: value,
                isProvisional: total.hasProvisionalValues
            )
        }
        .sorted { $0.date < $1.date }
        if let forecastValue = dailyCumulativeTrend.forecastPoints.last?.value {
            points.removeAll { calendar.isDate($0.date, inSameDayAs: today) }
            points.append(NutritionTrendPoint(
                date: today,
                value: forecastValue,
                isForecast: true
            ))
            points.sort { $0.date < $1.date }
        }

        return NutritionTrendsSnapshot(
            range: range,
            nutrient: nutrient,
            interval: interval,
            points: points,
            dailyCumulativeTrend: dailyCumulativeTrend,
            periodComparison: makePeriodComparison(
                for: date,
                dayCount: range.dayCount,
                goals: goals,
                calendar: calendar,
                dailyTotals: allTotals
            )
        )
    }

    static func makeDailyCumulativeTrend(
        for date: Date,
        nutrient: NutrientIdentifier,
        meals: [Meal],
        calendar: Calendar
    ) -> DailyCumulativeNutritionTrend {
        let activeRevisions = ActiveMealRevisionSnapshot(meals: meals)
        return makeDailyCumulativeTrend(
            for: date,
            nutrient: nutrient,
            meals: meals,
            calendar: calendar,
            portionMultipliers: PortionMultiplierSnapshot(),
            activeRevisions: activeRevisions
        )
    }

    private static func makeDailyCumulativeTrend(
        for date: Date,
        nutrient: NutrientIdentifier,
        meals: [Meal],
        calendar: Calendar,
        portionMultipliers: PortionMultiplierSnapshot,
        activeRevisions: ActiveMealRevisionSnapshot
    ) -> DailyCumulativeNutritionTrend {
        guard let selectedDay = calendar.dateInterval(of: .day, for: date) else {
            return DailyCumulativeNutritionTrend(
                actualPoints: [],
                averagePoints: [],
                forecastPoints: [],
                hasActualData: false,
                averageDayCount: 0,
                forecastDayCount: 0,
                hasProvisionalValues: false
            )
        }

        let includedMeals = meals.filter { meal in
            meal.mealState != .archived &&
                meal.timestamp < selectedDay.end &&
                activeRevisions.revision(for: meal)?.status.includesNutritionEstimate == true
        }
        let selectedDayMeals = includedMeals.filter { meal in
            meal.timestamp >= selectedDay.start
        }
        let historicalMeals = includedMeals.filter { $0.timestamp < selectedDay.start }
        let recordedDays = Set(historicalMeals.map { calendar.startOfDay(for: $0.timestamp) })
            .sorted(by: >)
            .prefix(90)
        let recordedDaySet = Set(recordedDays)
        let averageMeals = historicalMeals.filter {
            recordedDaySet.contains(calendar.startOfDay(for: $0.timestamp))
        }
        let actualEndHour = max(
            localHour(for: date, calendar: calendar),
            selectedDayMeals.map { localHour(for: $0.timestamp, calendar: calendar) }.max() ?? 0
        )

        let actualPoints = cumulativePoints(
            meals: selectedDayMeals,
            nutrient: nutrient,
            divisor: 1,
            endHour: min(actualEndHour, 24),
            calendar: calendar,
            portionMultipliers: portionMultipliers,
            activeRevisions: activeRevisions
        )
        let actualValue = actualPoints.last?.value ?? 0
        let emptyActualPoints = actualEndHour > 0
            ? [
                CumulativeNutritionTrendPoint(hour: 0, value: 0),
                CumulativeNutritionTrendPoint(hour: min(actualEndHour, 24), value: 0),
            ]
            : [CumulativeNutritionTrendPoint(hour: 0, value: 0)]
        return DailyCumulativeNutritionTrend(
            actualPoints: actualPoints.isEmpty ? emptyActualPoints : actualPoints,
            averagePoints: cumulativePoints(
                meals: averageMeals,
                nutrient: nutrient,
                divisor: max(Double(recordedDaySet.count), 1),
                endHour: 24,
                calendar: calendar,
                portionMultipliers: portionMultipliers,
                activeRevisions: activeRevisions
            ),
            forecastPoints: forecastPoints(
                historicalMeals: averageMeals,
                recordedDays: recordedDaySet,
                selectedDay: selectedDay.start,
                currentHour: min(actualEndHour, 24),
                actualValue: actualValue,
                nutrient: nutrient,
                calendar: calendar,
                portionMultipliers: portionMultipliers,
                activeRevisions: activeRevisions
            ),
            hasActualData: !selectedDayMeals.isEmpty,
            averageDayCount: recordedDaySet.count,
            forecastDayCount: recordedDaySet.count,
            hasProvisionalValues: (selectedDayMeals + averageMeals).contains {
                activeRevisions.revision(for: $0)?.status.isProvisionalNutritionEstimate == true
            }
        )
    }

    private static func forecastPoints(
        historicalMeals: [Meal],
        recordedDays: Set<Date>,
        selectedDay: Date,
        currentHour: Double,
        actualValue: Double,
        nutrient: NutrientIdentifier,
        calendar: Calendar,
        portionMultipliers: PortionMultiplierSnapshot,
        activeRevisions: ActiveMealRevisionSnapshot
    ) -> [CumulativeNutritionTrendPoint] {
        guard recordedDays.count >= 3 else { return [] }
        let selectedWeekday = calendar.component(.weekday, from: selectedDay)
        let weightsByDay = Dictionary(uniqueKeysWithValues: recordedDays.map { day in
            let weight = calendar.component(.weekday, from: day) == selectedWeekday ? 2.0 : 1.0
            return (day, weight)
        })
        let totalWeight = weightsByDay.values.reduce(0, +)
        guard totalWeight > 0 else { return [] }

        var weightedValuesByHour: [Double: Double] = [:]
        for meal in historicalMeals {
            let hour = localHour(for: meal.timestamp, calendar: calendar)
            guard hour > currentHour,
                  let revision = activeRevisions.revision(for: meal),
                  let value = portionMultipliers.scaledValue(
                    for: nutrient,
                    in: revision
                  ) else {
                continue
            }
            let day = calendar.startOfDay(for: meal.timestamp)
            guard let weight = weightsByDay[day] else { continue }
            weightedValuesByHour[hour, default: 0] +=
                value * weight / totalWeight
        }

        var forecastValue = actualValue
        var points = [CumulativeNutritionTrendPoint(hour: currentHour, value: actualValue)]
        for hour in weightedValuesByHour.keys.sorted() {
            forecastValue += weightedValuesByHour[hour, default: 0]
            points.append(CumulativeNutritionTrendPoint(hour: hour, value: forecastValue))
        }
        points.append(CumulativeNutritionTrendPoint(hour: 24, value: forecastValue))
        return points
    }

    private static func cumulativePoints(
        meals: [Meal],
        nutrient: NutrientIdentifier,
        divisor: Double,
        endHour: Double,
        calendar: Calendar,
        portionMultipliers: PortionMultiplierSnapshot,
        activeRevisions: ActiveMealRevisionSnapshot
    ) -> [CumulativeNutritionTrendPoint] {
        guard !meals.isEmpty else { return [] }
        var valuesByHour: [Double: Double] = [:]
        for meal in meals {
            guard let revision = activeRevisions.revision(for: meal),
                  let value = portionMultipliers.scaledValue(
                    for: nutrient,
                    in: revision
                  ) else {
                continue
            }
            valuesByHour[localHour(for: meal.timestamp, calendar: calendar), default: 0] +=
                value / divisor
        }

        var cumulativeValue = 0.0
        var points = [CumulativeNutritionTrendPoint(hour: 0, value: 0)]
        for hour in valuesByHour.keys.sorted() {
            cumulativeValue += valuesByHour[hour, default: 0]
            points.append(CumulativeNutritionTrendPoint(hour: hour, value: cumulativeValue))
        }
        let finalHour = max(endHour, valuesByHour.keys.max() ?? 0)
        if points.last?.hour != finalHour {
            points.append(CumulativeNutritionTrendPoint(
                hour: finalHour,
                value: cumulativeValue
            ))
        }
        return points
    }

    private static func localHour(for date: Date, calendar: Calendar) -> Double {
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double(components.hour ?? 0) +
            Double(components.minute ?? 0) / 60 +
            Double(components.second ?? 0) / 3_600
    }

    private static func makePeriodComparison(
        for date: Date,
        dayCount: Int,
        goals: [NutritionGoalPeriod],
        calendar: Calendar,
        dailyTotals: [DailyTotal]
    ) -> NutritionPeriodComparison {
        let currentEnd = calendar.startOfDay(for: date)
        let currentStart = calendar.date(
            byAdding: .day,
            value: -dayCount,
            to: currentEnd
        ) ?? currentEnd
        let currentInterval = DateInterval(start: currentStart, end: currentEnd)
        let previousStart = calendar.date(
            byAdding: .day,
            value: -dayCount,
            to: currentInterval.start
        ) ?? currentInterval.start
        let previousInterval = DateInterval(start: previousStart, end: currentInterval.start)

        return NutritionPeriodComparison(
            current: summary(
                for: currentInterval,
                calendarDayCount: dayCount,
                goals: goals,
                calendar: calendar,
                dailyTotals: dailyTotals
            ),
            previous: summary(
                for: previousInterval,
                calendarDayCount: dayCount,
                goals: goals,
                calendar: calendar,
                dailyTotals: dailyTotals
            )
        )
    }

    private static func summary(
        for interval: DateInterval,
        calendarDayCount: Int,
        goals: [NutritionGoalPeriod],
        calendar: Calendar,
        dailyTotals: [DailyTotal]
    ) -> NutritionPeriodSummary {
        let days = dailyTotals.filter {
            $0.date >= interval.start && $0.date < interval.end
        }
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

        return NutritionPeriodSummary(
            interval: interval,
            calendarDayCount: calendarDayCount,
            trackedDayCount: days.count,
            totals: totals,
            daysAboveEnergyTarget: above,
            daysAtOrBelowEnergyTarget: atOrBelow,
            hasProvisionalValues: days.contains(where: \.hasProvisionalValues)
        )
    }

    private struct DailyTotal {
        let date: Date
        let values: [NutrientIdentifier: Double]
        let hasProvisionalValues: Bool
    }

    private static func dailyTotals(
        meals: [Meal],
        within interval: DateInterval,
        calendar: Calendar,
        portionMultipliers: PortionMultiplierSnapshot,
        activeRevisions: ActiveMealRevisionSnapshot
    ) -> [DailyTotal] {
        let includedMeals = meals.filter { meal in
            meal.mealState != .archived &&
                meal.timestamp >= interval.start &&
                meal.timestamp < interval.end &&
                activeRevisions.revision(for: meal)?.status.includesNutritionEstimate == true
        }
        let grouped = Dictionary(grouping: includedMeals) {
            calendar.startOfDay(for: $0.timestamp)
        }
        return grouped.map { date, meals in
            var values: [NutrientIdentifier: Double] = [:]
            for meal in meals {
                guard let revision = activeRevisions.revision(for: meal) else { continue }
                for identifier in comparedNutrients {
                    guard let value = portionMultipliers.scaledValue(
                        for: identifier,
                        in: revision
                    ) else { continue }
                    values[identifier, default: 0] += value
                }
            }
            return DailyTotal(
                date: date,
                values: values,
                hasProvisionalValues: meals.contains {
                    activeRevisions.revision(for: $0)?.status.isProvisionalNutritionEstimate == true
                }
            )
        }
    }

    static func dateInterval(
        for date: Date,
        range: NutritionTrendRange,
        calendar: Calendar
    ) -> DateInterval? {
        guard let end = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: date)
        ), let start = calendar.date(
            byAdding: .day,
            value: -range.dayCount,
            to: end
        ) else { return nil }
        return DateInterval(start: start, end: end)
    }
}

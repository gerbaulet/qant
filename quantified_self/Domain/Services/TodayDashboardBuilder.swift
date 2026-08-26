import Foundation

struct NutrientProgress: Identifiable, Sendable {
    let id: NutrientIdentifier
    let consumed: Double
    let target: Double?
    let unit: NutrientUnit

    var remaining: Double? {
        target.map { $0 - consumed }
    }

    var fractionCompleted: Double? {
        guard let target, target > 0 else { return nil }
        return consumed / target
    }
}

struct TodayMealSummary: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let name: String?
    let energyKilocalories: Double?
    let analysisState: AnalysisState
    let isProvisional: Bool
    let thumbnailStorageKey: String?
}

struct TodayDashboardSnapshot: Sendable {
    let date: Date
    let energy: NutrientProgress
    let weeklyEnergy: NutrientProgress
    let macros: [NutrientProgress]
    let fiber: NutrientProgress
    let meals: [TodayMealSummary]
    let hasProvisionalValues: Bool
}

/// Converts persisted entities into immutable presentation data. Views do not
/// decide which revisions count or how local-day boundaries are calculated.
@MainActor
enum TodayDashboardBuilder {
    private static let macroIdentifiers: [NutrientIdentifier] = [
        .protein,
        .carbohydrates,
        .fat,
    ]

    static func makeSnapshot(
        for date: Date,
        meals: [Meal],
        goals: [NutritionGoalPeriod],
        calendar: Calendar
    ) -> TodayDashboardSnapshot {
        guard let dayInterval = calendar.dateInterval(of: .day, for: date) else {
            return emptySnapshot(for: date, goals: goals)
        }

        let todaysMeals = meals
            .filter {
                $0.timestamp >= dayInterval.start &&
                    $0.timestamp < dayInterval.end
            }
            .sorted { $0.timestamp > $1.timestamp }

        let includedRevisions = todaysMeals.compactMap { meal -> MealAnalysisRevision? in
            guard let revision = meal.activeRevision,
                  isIncludedInProvisionalTotals(revision.status) else {
                return nil
            }
            return revision
        }

        let weeklyEnergy = makeWeeklyEnergyProgress(
            for: date,
            meals: meals,
            goals: goals,
            calendar: calendar
        )

        let energy = progress(
            for: .energy,
            unit: .kilocalorie,
            revisions: includedRevisions,
            goals: goals,
            at: dayInterval.start
        )
        let macros = macroIdentifiers.map {
            progress(
                for: $0,
                unit: .gram,
                revisions: includedRevisions,
                goals: goals,
                at: dayInterval.start
            )
        }
        let fiber = progress(
            for: .fiber,
            unit: .gram,
            revisions: includedRevisions,
            goals: goals,
            at: dayInterval.start
        )

        let summaries = todaysMeals.map { meal in
            let revision = meal.activeRevision
            let included = revision.map { isIncludedInProvisionalTotals($0.status) } ?? false
            return TodayMealSummary(
                id: meal.id,
                timestamp: meal.timestamp,
                name: revision?.mealName,
                energyKilocalories: included
                    ? nutrientTotal(for: .energy, unit: .kilocalorie, in: [revision].compactMap { $0 })
                    : nil,
                analysisState: meal.analysisState,
                isProvisional: included && revision?.status != .confirmed,
                thumbnailStorageKey: meal.images.min(by: { $0.sortIndex < $1.sortIndex })?.thumbnailStorageKey
            )
        }

        return TodayDashboardSnapshot(
            date: date,
            energy: energy,
            weeklyEnergy: weeklyEnergy,
            macros: macros,
            fiber: fiber,
            meals: summaries,
            hasProvisionalValues: includedRevisions.contains { $0.status != .confirmed }
        )
    }

    private static func progress(
        for identifier: NutrientIdentifier,
        unit: NutrientUnit,
        revisions: [MealAnalysisRevision],
        goals: [NutritionGoalPeriod],
        at date: Date
    ) -> NutrientProgress {
        NutrientProgress(
            id: identifier,
            consumed: nutrientTotal(for: identifier, unit: unit, in: revisions),
            target: GoalHistory.goal(for: identifier, at: date, in: goals)?.targetValue,
            unit: unit
        )
    }

    private static func nutrientTotal(
        for identifier: NutrientIdentifier,
        unit: NutrientUnit,
        in revisions: [MealAnalysisRevision]
    ) -> Double {
        revisions.reduce(0) { total, revision in
            total + revision.nutrients
                .filter {
                    $0.identifierRawValue == identifier.rawValue &&
                        $0.unitRawValue == unit.rawValue
                }
                .reduce(0) { $0 + revision.scaled($1.value) }
        }
    }

    private static func isIncludedInProvisionalTotals(_ state: AnalysisState) -> Bool {
        switch state {
        case .needsClarification, .awaitingConfirmation, .confirmed:
            true
        case .pending, .analyzing, .failed:
            false
        }
    }

    private static func makeWeeklyEnergyProgress(
        for date: Date,
        meals: [Meal],
        goals: [NutritionGoalPeriod],
        calendar: Calendar
    ) -> NutrientProgress {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: date) else {
            return NutrientProgress(id: .energy, consumed: 0, target: nil, unit: .kilocalorie)
        }
        let revisions = meals.compactMap { meal -> MealAnalysisRevision? in
            guard meal.timestamp >= week.start,
                  meal.timestamp < week.end,
                  let revision = meal.activeRevision,
                  isIncludedInProvisionalTotals(revision.status) else {
                return nil
            }
            return revision
        }
        let target = (try? GoalHistory.weeklyTarget(
            for: .energy,
            containing: date,
            calendar: calendar,
            periods: goals
        )) ?? nil
        return NutrientProgress(
            id: .energy,
            consumed: nutrientTotal(for: .energy, unit: .kilocalorie, in: revisions),
            target: target,
            unit: .kilocalorie
        )
    }

    private static func emptySnapshot(
        for date: Date,
        goals: [NutritionGoalPeriod]
    ) -> TodayDashboardSnapshot {
        let target: (NutrientIdentifier, NutrientUnit) -> Double? = { identifier, _ in
            GoalHistory.goal(for: identifier, at: date, in: goals)?.targetValue
        }
        return TodayDashboardSnapshot(
            date: date,
            energy: NutrientProgress(
                id: .energy,
                consumed: 0,
                target: target(.energy, .kilocalorie),
                unit: .kilocalorie
            ),
            weeklyEnergy: NutrientProgress(
                id: .energy,
                consumed: 0,
                target: (try? GoalHistory.weeklyTarget(
                    for: .energy,
                    containing: date,
                    calendar: .autoupdatingCurrent,
                    periods: goals
                )) ?? nil,
                unit: .kilocalorie
            ),
            macros: macroIdentifiers.map {
                NutrientProgress(
                    id: $0,
                    consumed: 0,
                    target: target($0, .gram),
                    unit: .gram
                )
            },
            fiber: NutrientProgress(
                id: .fiber,
                consumed: 0,
                target: target(.fiber, .gram),
                unit: .gram
            ),
            meals: [],
            hasProvisionalValues: false
        )
    }
}

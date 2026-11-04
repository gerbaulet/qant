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
    let hasProvisionalWeeklyValues: Bool
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
        makeSnapshot(
            for: date,
            meals: meals,
            goals: goals,
            calendar: calendar,
            portionMultipliers: PortionMultiplierSnapshot(),
            activeRevisions: ActiveMealRevisionSnapshot(meals: meals)
        )
    }

    static func makeSnapshot(
        for date: Date,
        meals: [Meal],
        goals: [NutritionGoalPeriod],
        calendar: Calendar,
        portionMultipliers: PortionMultiplierSnapshot,
        activeRevisions: ActiveMealRevisionSnapshot
    ) -> TodayDashboardSnapshot {
        guard let dayInterval = calendar.dateInterval(of: .day, for: date) else {
            return emptySnapshot(for: date, goals: goals)
        }

        let todaysMeals = meals
            .filter {
                $0.mealState != .archived &&
                    $0.timestamp >= dayInterval.start &&
                    $0.timestamp < dayInterval.end
            }
            .sorted { $0.timestamp > $1.timestamp }
        let includedRevisions = todaysMeals.compactMap { meal -> MealAnalysisRevision? in
            guard let revision = activeRevisions.revision(for: meal),
                  revision.status.includesNutritionEstimate else {
                return nil
            }
            return revision
        }
        let dailyTotals = nutrientTotals(
            in: includedRevisions,
            portionMultipliers: portionMultipliers
        )

        let weeklyEnergy = makeWeeklyEnergyProgress(
            for: date,
            meals: meals,
            goals: goals,
            calendar: calendar,
            portionMultipliers: portionMultipliers,
            activeRevisions: activeRevisions
        )

        let energy = progress(
            for: .energy,
            unit: .kilocalorie,
            consumed: dailyTotals[.energy, default: 0],
            goals: goals,
            at: dayInterval.start
        )
        let macros = macroIdentifiers.map {
            progress(
                for: $0,
                unit: .gram,
                consumed: dailyTotals[$0, default: 0],
                goals: goals,
                at: dayInterval.start
            )
        }
        let fiber = progress(
            for: .fiber,
            unit: .gram,
            consumed: dailyTotals[.fiber, default: 0],
            goals: goals,
            at: dayInterval.start
        )

        let summaries = todaysMeals.map { meal in
            let revision = activeRevisions.revision(for: meal)
            let included = revision?.status.includesNutritionEstimate ?? false
            return TodayMealSummary(
                id: meal.id,
                timestamp: meal.timestamp,
                name: revision?.mealName,
                energyKilocalories: included
                    ? nutrientTotal(
                        for: .energy,
                        unit: .kilocalorie,
                        in: [revision].compactMap { $0 },
                        portionMultipliers: portionMultipliers
                    )
                    : nil,
                analysisState: meal.analysisState,
                isProvisional: revision?.status.isProvisionalNutritionEstimate ?? false,
                thumbnailStorageKey: meal.images.min(by: { $0.sortIndex < $1.sortIndex })?.thumbnailStorageKey
            )
        }

        return TodayDashboardSnapshot(
            date: date,
            energy: energy,
            weeklyEnergy: weeklyEnergy.progress,
            macros: macros,
            fiber: fiber,
            meals: summaries,
            hasProvisionalValues: includedRevisions.contains { $0.status.isProvisionalNutritionEstimate },
            hasProvisionalWeeklyValues: weeklyEnergy.hasProvisionalValues
        )
    }

    private static func progress(
        for identifier: NutrientIdentifier,
        unit: NutrientUnit,
        consumed: Double,
        goals: [NutritionGoalPeriod],
        at date: Date
    ) -> NutrientProgress {
        NutrientProgress(
            id: identifier,
            consumed: consumed,
            target: GoalHistory.goal(for: identifier, at: date, in: goals)?.targetValue,
            unit: unit
        )
    }

    private static func nutrientTotals(
        in revisions: [MealAnalysisRevision],
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

    private static func nutrientTotal(
        for identifier: NutrientIdentifier,
        unit: NutrientUnit,
        in revisions: [MealAnalysisRevision],
        portionMultipliers: PortionMultiplierSnapshot
    ) -> Double {
        revisions.reduce(0) { total, revision in
            total + revision.nutrients
                .filter {
                    $0.identifierRawValue == identifier.rawValue &&
                        $0.unitRawValue == unit.rawValue
                }
                .reduce(0) { $0 + portionMultipliers.scaled($1, for: revision) }
        }
    }

    private static func makeWeeklyEnergyProgress(
        for date: Date,
        meals: [Meal],
        goals: [NutritionGoalPeriod],
        calendar: Calendar,
        portionMultipliers: PortionMultiplierSnapshot,
        activeRevisions: ActiveMealRevisionSnapshot
    ) -> (progress: NutrientProgress, hasProvisionalValues: Bool) {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: date) else {
            return (
                NutrientProgress(id: .energy, consumed: 0, target: nil, unit: .kilocalorie),
                false
            )
        }
        let revisions = meals.compactMap { meal -> MealAnalysisRevision? in
            guard meal.mealState != .archived,
                  meal.timestamp >= week.start,
                  meal.timestamp < week.end,
                  let revision = activeRevisions.revision(for: meal),
                  revision.status.includesNutritionEstimate else {
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
        return (
            NutrientProgress(
                id: .energy,
                consumed: nutrientTotal(
                    for: .energy,
                    unit: .kilocalorie,
                    in: revisions,
                    portionMultipliers: portionMultipliers
                ),
                target: target,
                unit: .kilocalorie
            ),
            revisions.contains { $0.status.isProvisionalNutritionEstimate }
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
            hasProvisionalValues: false,
            hasProvisionalWeeklyValues: false
        )
    }
}

struct TodayDashboardPresentation {
    let snapshot: TodayDashboardSnapshot
    let weeklySummary: WeeklyNutritionSummary?
}

@MainActor
enum TodayDashboardPresentationBuilder {
    static func makePresentation(
        for date: Date,
        meals: [Meal],
        goals: [NutritionGoalPeriod],
        calendar: Calendar
    ) -> TodayDashboardPresentation {
        let portionMultipliers = PortionMultiplierSnapshot()
        let activeRevisions = ActiveMealRevisionSnapshot(meals: meals)
        return TodayDashboardPresentation(
            snapshot: TodayDashboardBuilder.makeSnapshot(
                for: date,
                meals: meals,
                goals: goals,
                calendar: calendar,
                portionMultipliers: portionMultipliers,
                activeRevisions: activeRevisions
            ),
            weeklySummary: WeeklyNutritionSummaryBuilder.makeSummary(
                containing: date,
                meals: meals,
                goals: goals,
                calendar: calendar,
                portionMultipliers: portionMultipliers,
                activeRevisions: activeRevisions
            )
        )
    }
}

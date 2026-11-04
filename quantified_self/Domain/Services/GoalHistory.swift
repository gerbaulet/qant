import Foundation

enum GoalHistoryError: Error, Equatable {
    case invalidTarget
    case unableToDetermineWeek
    case unableToAdvanceDay
}

struct GoalChange: Equatable, Sendable {
    let nutrient: NutrientIdentifier
    let targetValue: Double
    let unit: NutrientUnit
}

/// Pure date and target logic shared by Settings, Today, and Trends.
///
/// Periods are half-open: `validFrom` is included and `validUntil` is excluded.
/// If corrupt/imported data overlaps, the most recently started matching period
/// wins deterministically; `overlappingPeriodIDs` lets callers surface or repair
/// that invalid state.
@MainActor
enum GoalHistory {
    static func goal(
        for nutrient: NutrientIdentifier,
        at date: Date,
        in periods: [NutritionGoalPeriod]
    ) -> NutritionGoalPeriod? {
        periods
            .filter {
                $0.nutrientIdentifierRawValue == nutrient.rawValue &&
                    $0.contains(date)
            }
            .max { $0.validFrom < $1.validFrom }
    }

    /// Inserts a new effective-dated value without changing earlier history.
    /// The caller persists the returned model in its SwiftData context.
    @discardableResult
    static func applyChange(
        for nutrient: NutrientIdentifier,
        targetValue: Double,
        unit: NutrientUnit,
        effectiveOn date: Date,
        calendar: Calendar,
        periods: [NutritionGoalPeriod],
        now: Date = .now
    ) throws -> NutritionGoalPeriod {
        guard targetValue.isFinite, targetValue > 0 else {
            throw GoalHistoryError.invalidTarget
        }

        let effectiveFrom = calendar.startOfDay(for: date)
        let matching = periods.filter {
            $0.nutrientIdentifierRawValue == nutrient.rawValue
        }

        if let existing = matching.first(where: { $0.validFrom == effectiveFrom }) {
            existing.targetValue = targetValue
            existing.unitRawValue = unit.rawValue
            existing.modifiedAt = now
            return existing
        }

        for previous in matching where previous.contains(effectiveFrom) {
            previous.validUntil = effectiveFrom
            previous.modifiedAt = now
        }

        let nextStart = matching
            .lazy
            .map(\.validFrom)
            .filter { $0 > effectiveFrom }
            .min()

        return NutritionGoalPeriod(
            createdAt: now,
            modifiedAt: now,
            validFrom: effectiveFrom,
            validUntil: nextStart,
            nutrientIdentifier: nutrient,
            targetValue: targetValue,
            unit: unit
        )
    }

    /// Validates the entire batch before mutating any existing period.
    /// Callers can therefore present several editable goals as one atomic form.
    static func applyChanges(
        _ changes: [GoalChange],
        effectiveOn date: Date,
        calendar: Calendar,
        periods: [NutritionGoalPeriod],
        now: Date = .now
    ) throws -> [NutritionGoalPeriod] {
        guard changes.allSatisfy({ $0.targetValue.isFinite && $0.targetValue > 0 }) else {
            throw GoalHistoryError.invalidTarget
        }

        var availablePeriods = periods
        var changedPeriods: [NutritionGoalPeriod] = []

        for change in changes {
            let current = goal(for: change.nutrient, at: date, in: availablePeriods)
            guard current?.targetValue != change.targetValue || current?.unit != change.unit else {
                continue
            }

            let changed = try applyChange(
                for: change.nutrient,
                targetValue: change.targetValue,
                unit: change.unit,
                effectiveOn: date,
                calendar: calendar,
                periods: availablePeriods,
                now: now
            )
            changedPeriods.append(changed)

            if !availablePeriods.contains(where: { $0.id == changed.id }) {
                availablePeriods.append(changed)
            }
        }

        return changedPeriods
    }

    /// Returns `nil` rather than silently treating a day with no configured goal
    /// as zero. The UI can then explain that the weekly target is incomplete.
    static func weeklyTarget(
        for nutrient: NutrientIdentifier,
        containing date: Date,
        calendar: Calendar,
        periods: [NutritionGoalPeriod]
    ) throws -> Double? {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: date) else {
            throw GoalHistoryError.unableToDetermineWeek
        }

        var total = 0.0
        var day = calendar.startOfDay(for: week.start)

        while day < week.end {
            guard let period = goal(for: nutrient, at: day, in: periods) else {
                return nil
            }
            total += period.targetValue

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else {
                throw GoalHistoryError.unableToAdvanceDay
            }
            day = nextDay
        }

        return total
    }

    static func overlappingPeriodIDs(
        for nutrient: NutrientIdentifier,
        in periods: [NutritionGoalPeriod]
    ) -> [(UUID, UUID)] {
        let sorted = periods
            .filter { $0.nutrientIdentifierRawValue == nutrient.rawValue }
            .sorted { $0.validFrom < $1.validFrom }

        var overlaps: [(UUID, UUID)] = []
        for (index, period) in sorted.enumerated() {
            for candidate in sorted.dropFirst(index + 1) {
                guard period.validUntil == nil || candidate.validFrom < period.validUntil! else {
                    break
                }
                overlaps.append((period.id, candidate.id))
            }
        }
        return overlaps
    }
}

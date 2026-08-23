import Foundation
import Testing
@testable import quantified_self

@MainActor
struct GoalHistoryTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "de_DE")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    @Test("Historical lookup uses half-open date boundaries")
    func historicalLookupAndBoundary() {
        let oldGoal = goal(from: date(2026, 1, 1), until: date(2026, 4, 1), value: 2_300)
        let currentGoal = goal(from: date(2026, 4, 1), value: 2_200)
        let periods = [currentGoal, oldGoal]

        #expect(GoalHistory.goal(for: .energy, at: date(2026, 3, 31, 23), in: periods)?.targetValue == 2_300)
        #expect(GoalHistory.goal(for: .energy, at: date(2026, 4, 1), in: periods)?.targetValue == 2_200)
    }

    @Test("Changing a goal closes the active period without rewriting its value")
    func changePreservesHistory() throws {
        let original = goal(from: date(2026, 1, 1), value: 2_300)

        let replacement = try GoalHistory.applyChange(
            for: .energy,
            targetValue: 2_100,
            unit: .kilocalorie,
            effectiveOn: date(2026, 6, 16, 18),
            calendar: calendar,
            periods: [original],
            now: date(2026, 6, 15)
        )

        #expect(original.targetValue == 2_300)
        #expect(original.validUntil == date(2026, 6, 16))
        #expect(replacement.validFrom == date(2026, 6, 16))
        #expect(replacement.targetValue == 2_100)
    }

    @Test("A same-day change updates that day's period instead of overlapping it")
    func sameDayChange() throws {
        let existing = goal(from: date(2026, 8, 23), value: 2_200)

        let result = try GoalHistory.applyChange(
            for: .energy,
            targetValue: 2_150,
            unit: .kilocalorie,
            effectiveOn: date(2026, 8, 23, 17),
            calendar: calendar,
            periods: [existing]
        )

        #expect(result === existing)
        #expect(existing.targetValue == 2_150)
    }

    @Test("Weekly target sums goals across a mid-week change")
    func weeklyTargetWithMidweekChange() throws {
        let oldGoal = goal(from: date(2026, 8, 1), until: date(2026, 8, 20), value: 2_200)
        let newGoal = goal(from: date(2026, 8, 20), value: 2_100)

        let target = try GoalHistory.weeklyTarget(
            for: .energy,
            containing: date(2026, 8, 19),
            calendar: calendar,
            periods: [oldGoal, newGoal]
        )

        // Monday-Wednesday at 2,200 + Thursday-Sunday at 2,100.
        #expect(target == 15_000)
    }

    @Test("A week with an unconfigured day has no misleading partial target")
    func incompleteWeeklyTarget() throws {
        let lateGoal = goal(from: date(2026, 8, 20), value: 2_100)

        let target = try GoalHistory.weeklyTarget(
            for: .energy,
            containing: date(2026, 8, 19),
            calendar: calendar,
            periods: [lateGoal]
        )

        #expect(target == nil)
    }

    @Test("Overlaps are detectable and lookup resolves to the latest start")
    func overlapHandling() {
        let earlier = goal(from: date(2026, 1, 1), value: 2_300)
        let later = goal(from: date(2026, 4, 1), value: 2_200)
        let periods = [earlier, later]

        #expect(GoalHistory.overlappingPeriodIDs(for: .energy, in: periods).count == 1)
        #expect(GoalHistory.goal(for: .energy, at: date(2026, 5, 1), in: periods) === later)
    }

    @Test("Invalid target values are rejected")
    func invalidTarget() {
        #expect(throws: GoalHistoryError.invalidTarget) {
            try GoalHistory.applyChange(
                for: .energy,
                targetValue: -.infinity,
                unit: .kilocalorie,
                effectiveOn: date(2026, 8, 23),
                calendar: calendar,
                periods: []
            )
        }
    }

    private func goal(
        from: Date,
        until: Date? = nil,
        value: Double
    ) -> NutritionGoalPeriod {
        NutritionGoalPeriod(
            validFrom: from,
            validUntil: until,
            nutrientIdentifier: .energy,
            targetValue: value,
            unit: .kilocalorie
        )
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour
        ))!
    }
}

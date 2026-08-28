import Foundation
import Testing
@testable import Quant

@MainActor
struct NutritionTrendsBuilderTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "de_DE")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }

    @Test("Trend points include confirmed meals only and combine each local day")
    func confirmedDailyPoints() {
        let first = meal(at: date(2026, 8, 5, 8), state: .confirmed, energy: 500, protein: 25)
        let second = meal(at: date(2026, 8, 5, 19), state: .confirmed, energy: 700, protein: 35)
        let provisional = meal(at: date(2026, 8, 6, 12), state: .awaitingConfirmation, energy: 900, protein: 50)

        let snapshot = NutritionTrendsBuilder.makeSnapshot(
            for: date(2026, 8, 23, 12),
            range: .month,
            nutrient: .energy,
            meals: [first, second, provisional],
            goals: [],
            calendar: calendar
        )

        #expect(snapshot.points.count == 1)
        #expect(snapshot.points.first?.value == 1_200)
    }

    @Test("Month-to-date compares the same number of previous-month calendar days")
    func fairPartialMonthComparison() {
        let currentOne = meal(at: date(2026, 8, 2, 12), state: .confirmed, energy: 2_000, protein: 100)
        let currentTwo = meal(at: date(2026, 8, 20, 12), state: .confirmed, energy: 2_200, protein: 120)
        let previousIncluded = meal(at: date(2026, 7, 10, 12), state: .confirmed, energy: 1_800, protein: 90)
        let previousTooLate = meal(at: date(2026, 7, 28, 12), state: .confirmed, energy: 5_000, protein: 200)

        let comparison = NutritionTrendsBuilder.makeSnapshot(
            for: date(2026, 8, 23, 12),
            range: .month,
            nutrient: .energy,
            meals: [currentOne, currentTwo, previousIncluded, previousTooLate],
            goals: [],
            calendar: calendar
        ).monthlyComparison

        #expect(comparison.current.calendarDayCount == 23)
        #expect(comparison.previous.calendarDayCount == 23)
        #expect(comparison.current.trackedDayCount == 2)
        #expect(comparison.previous.trackedDayCount == 1)
        #expect(comparison.current.average(for: .energy) == 2_100)
        #expect(comparison.previous.average(for: .energy) == 1_800)
        #expect(abs((comparison.percentChange(for: .energy) ?? 0) - 16.6667) < 0.001)
    }

    @Test("Unlogged days are coverage gaps rather than zero-calorie days")
    func missingDaysDoNotDiluteAverage() {
        let tracked = meal(at: date(2026, 8, 10, 12), state: .confirmed, energy: 2_000, protein: 100)
        let goal = NutritionGoalPeriod(
            validFrom: date(2026, 1, 1),
            nutrientIdentifier: .energy,
            targetValue: 2_200,
            unit: .kilocalorie
        )

        let current = NutritionTrendsBuilder.makeSnapshot(
            for: date(2026, 8, 23, 12),
            range: .month,
            nutrient: .energy,
            meals: [tracked],
            goals: [goal],
            calendar: calendar
        ).monthlyComparison.current

        #expect(current.trackedDayCount == 1)
        #expect(current.calendarDayCount == 23)
        #expect(current.average(for: .energy) == 2_000)
        #expect(current.daysAtOrBelowEnergyTarget == 1)
    }

    @Test("Daily trend accumulates meals at their local time")
    func dailyCumulativeTrend() {
        let breakfast = meal(at: date(2026, 8, 23, 8, 30), state: .confirmed, energy: 500, protein: 25)
        let lunch = meal(at: date(2026, 8, 23, 12, 15), state: .confirmed, energy: 700, protein: 35)

        let trend = NutritionTrendsBuilder.makeDailyCumulativeTrend(
            for: date(2026, 8, 23, 14),
            nutrient: .energy,
            meals: [breakfast, lunch],
            calendar: calendar
        )

        #expect(trend.hasActualData)
        #expect(trend.actualPoints.map(\.hour) == [0, 8.5, 12.25, 14])
        #expect(trend.actualPoints.map(\.value) == [0, 500, 1_200, 1_200])
    }

    @Test("Daily average weights each recorded day equally and ignores missing days")
    func dailyAverageUsesRecordedDays() {
        let firstBreakfast = meal(at: date(2026, 8, 20, 8), state: .confirmed, energy: 600, protein: 30)
        let firstDinner = meal(at: date(2026, 8, 20, 18), state: .confirmed, energy: 400, protein: 20)
        let secondLunch = meal(at: date(2026, 8, 22, 10), state: .confirmed, energy: 300, protein: 15)

        let trend = NutritionTrendsBuilder.makeDailyCumulativeTrend(
            for: date(2026, 8, 23, 14),
            nutrient: .energy,
            meals: [firstBreakfast, firstDinner, secondLunch],
            calendar: calendar
        )

        #expect(trend.averageDayCount == 2)
        #expect(trend.averagePoints.map(\.hour) == [0, 8, 10, 18, 24])
        #expect(trend.averagePoints.map(\.value) == [0, 300, 450, 650, 650])
    }

    @Test("Daily average includes only the latest 90 recorded days")
    func dailyAverageLimitsRecordedDays() {
        let reference = date(2026, 8, 23, 14)
        let meals = (1...91).map { offset in
            let timestamp = calendar.date(byAdding: .day, value: -offset, to: reference)!
            return meal(
                at: timestamp,
                state: .confirmed,
                energy: offset == 91 ? 9_000 : 1,
                protein: 1
            )
        }

        let trend = NutritionTrendsBuilder.makeDailyCumulativeTrend(
            for: reference,
            nutrient: .energy,
            meals: meals,
            calendar: calendar
        )

        #expect(trend.averageDayCount == 90)
        #expect(abs((trend.averagePoints.last?.value ?? 0) - 1) < 0.000_001)
    }

    private func meal(
        at timestamp: Date,
        state: AnalysisState,
        energy: Double,
        protein: Double
    ) -> Meal {
        let revision = MealAnalysisRevision(
            modelIdentifier: "test/model",
            status: state,
            mealName: "Testmahlzeit",
            confidence: .medium,
            nutrients: [
                nutrient(.energy, energy, .kilocalorie),
                nutrient(.protein, protein, .gram),
            ]
        )
        return Meal(
            timestamp: timestamp,
            analysisState: state,
            activeRevisionID: revision.id,
            analysisRevisions: [revision]
        )
    }

    private func nutrient(
        _ identifier: NutrientIdentifier,
        _ value: Double,
        _ unit: NutrientUnit
    ) -> NutrientValue {
        NutrientValue(
            identifier: identifier,
            value: value,
            unit: unit,
            confidence: .medium,
            provenance: .visualEstimate
        )
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }
}

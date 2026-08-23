import Foundation
import Testing
@testable import quantified_self

@MainActor
struct WeeklyNutritionSummaryBuilderTests {
    private var berlinCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    @Test("Sunday belongs to the Monday-based week and compares daily averages")
    func sundayBoundaryAndComparison() throws {
        let calendar = berlinCalendar
        let summary = try #require(WeeklyNutritionSummaryBuilder.makeSummary(
            containing: date(2026, 8, 23, 20, calendar: calendar),
            meals: [
                meal(at: date(2026, 8, 17, 12, calendar: calendar), energy: 2_000, protein: 100),
                meal(at: date(2026, 8, 23, 19, calendar: calendar), energy: 2_400, protein: 120),
                meal(at: date(2026, 8, 10, 12, calendar: calendar), energy: 2_000, protein: 90),
            ],
            goals: [goal(from: date(2026, 1, 1, calendar: calendar))],
            calendar: calendar
        ))

        #expect(calendar.component(.weekday, from: summary.interval.start) == 2)
        #expect(summary.energyKilocalories == 4_400)
        #expect(summary.trackedDayCount == 2)
        #expect(summary.averageEnergyKilocalories == 2_200)
        #expect(summary.daysWithinEnergyTarget == 1)
        #expect(summary.daysAboveEnergyTarget == 1)
        #expect(summary.previousWeekAverageEnergyChangePercent == 10)
    }

    @Test("DST week uses calendar days and excludes provisional and archived meals")
    func daylightSavingWeek() throws {
        let calendar = berlinCalendar
        let reference = date(2026, 3, 29, 12, calendar: calendar)
        let confirmed = meal(at: date(2026, 3, 29, 1, calendar: calendar), energy: 800, protein: 40)
        let provisional = meal(at: date(2026, 3, 29, 3, calendar: calendar), energy: 900, protein: 50, state: .awaitingConfirmation)
        let archived = meal(at: date(2026, 3, 28, 12, calendar: calendar), energy: 700, protein: 30)
        archived.mealState = .archived

        let summary = try #require(WeeklyNutritionSummaryBuilder.makeSummary(
            containing: reference,
            meals: [confirmed, provisional, archived],
            goals: [goal(from: date(2026, 1, 1, calendar: calendar))],
            calendar: calendar
        ))

        #expect(summary.interval.duration == 167 * 60 * 60)
        #expect(summary.energyKilocalories == 800)
        #expect(summary.trackedDayCount == 1)
    }

    @Test("Reminder schedule is Sunday at 20:00 local time")
    func reminderDateComponents() {
        let components = WeeklySummaryNotificationSchedule.sundayEvening
        #expect(components.weekday == 1)
        #expect(components.hour == 20)
        #expect(components.minute == 0)
        #expect(components.timeZone == .autoupdatingCurrent)
    }

    private func goal(from date: Date) -> NutritionGoalPeriod {
        NutritionGoalPeriod(
            validFrom: date,
            nutrientIdentifier: .energy,
            targetValue: 2_200,
            unit: .kilocalorie
        )
    }

    private func meal(
        at timestamp: Date,
        energy: Double,
        protein: Double,
        state: AnalysisState = .confirmed
    ) -> Meal {
        let revision = MealAnalysisRevision(
            modelIdentifier: "test/model",
            status: state,
            mealName: "Test",
            confidence: .medium,
            nutrients: [
                NutrientValue(identifier: .energy, value: energy, unit: .kilocalorie, confidence: .medium, provenance: .visualEstimate),
                NutrientValue(identifier: .protein, value: protein, unit: .gram, confidence: .medium, provenance: .visualEstimate),
            ]
        )
        return Meal(timestamp: timestamp, analysisState: state, activeRevisionID: revision.id, analysisRevisions: [revision])
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
}

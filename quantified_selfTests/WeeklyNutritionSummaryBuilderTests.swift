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

    @Test("Sunday reminder temporarily repeats every evening at 20:00")
    func reminderDateComponents() {
        let components = WeeklySummaryNotificationSchedule.sundayEvening
        #expect(components.weekday == nil)
        #expect(components.hour == 20)
        #expect(components.minute == 0)
        #expect(components.timeZone == .autoupdatingCurrent)
    }

    @Test("Test reminder uses a separate one-time schedule")
    func testReminderSchedule() {
        #expect(WeeklySummaryNotificationSchedule.testIdentifier != WeeklySummaryNotificationSchedule.identifier)
        #expect(WeeklySummaryNotificationSchedule.testDelay == 5)
    }

    @Test("Weekly tips adapt a familiar breakfast to low fiber and protein")
    func personalizedWeeklyTips() throws {
        let calendar = berlinCalendar
        let goals = nutritionGoals(from: date(2026, 1, 1, calendar: calendar))
        let meals = [17, 18, 19].map { day in
            meal(
                at: date(2026, 8, day, 8, calendar: calendar),
                energy: 1_700,
                protein: 60,
                carbohydrates: 190,
                fat: 60,
                fiber: 12,
                name: "Joghurt mit Banane"
            )
        }

        let summary = try #require(WeeklyNutritionSummaryBuilder.makeSummary(
            containing: date(2026, 8, 23, 20, calendar: calendar),
            meals: meals,
            goals: goals,
            calendar: calendar
        ))

        #expect(summary.recommendations.map(\.kind) == [.increaseFiber, .increaseProtein])
        #expect(summary.recommendations.count == 2)
        #expect(summary.recommendations[0].message.contains("Joghurt"))
        #expect(summary.recommendations[1].message.contains("Frühstück"))
    }

    @Test("English titles and components still produce personalized German tips")
    func englishAnalysisTextProducesPersonalizedTips() throws {
        let calendar = berlinCalendar
        let meals = [17, 18, 19].map { day in
            meal(
                at: date(2026, 8, day, 8, calendar: calendar),
                energy: 1_700,
                protein: 60,
                carbohydrates: 190,
                fat: 60,
                fiber: 12,
                name: "Breakfast Bowl",
                componentNames: ["Greek Yogurt", "Oat Granola"]
            )
        }

        let summary = try #require(WeeklyNutritionSummaryBuilder.makeSummary(
            containing: date(2026, 8, 23, 20, calendar: calendar),
            meals: meals,
            goals: nutritionGoals(from: date(2026, 1, 1, calendar: calendar)),
            calendar: calendar
        ))

        #expect(summary.recommendations.map(\.kind) == [.increaseFiber, .increaseProtein])
        #expect(summary.recommendations[0].message.contains("Joghurt"))
        #expect(summary.recommendations[1].message.contains("Frühstück"))
    }

    @Test("Personal tips wait for three tracked days")
    func recommendationDataThreshold() throws {
        let calendar = berlinCalendar
        let summary = try #require(WeeklyNutritionSummaryBuilder.makeSummary(
            containing: date(2026, 8, 23, 20, calendar: calendar),
            meals: [
                meal(
                    at: date(2026, 8, 22, 8, calendar: calendar),
                    energy: 1_700,
                    protein: 60,
                    carbohydrates: 190,
                    fat: 60,
                    fiber: 12,
                    name: "Joghurt mit Banane"
                ),
            ],
            goals: nutritionGoals(from: date(2026, 1, 1, calendar: calendar)),
            calendar: calendar
        ))

        #expect(summary.recommendations.isEmpty)
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
        carbohydrates: Double = 0,
        fat: Double = 0,
        fiber: Double = 0,
        name: String = "Test",
        componentNames: [String] = [],
        state: AnalysisState = .confirmed
    ) -> Meal {
        let revision = MealAnalysisRevision(
            modelIdentifier: "test/model",
            status: state,
            mealName: name,
            confidence: .medium,
            components: componentNames.enumerated().map { index, name in
                FoodComponent(sortIndex: index, name: name)
            },
            nutrients: [
                NutrientValue(identifier: .energy, value: energy, unit: .kilocalorie, confidence: .medium, provenance: .visualEstimate),
                NutrientValue(identifier: .protein, value: protein, unit: .gram, confidence: .medium, provenance: .visualEstimate),
                NutrientValue(identifier: .carbohydrates, value: carbohydrates, unit: .gram, confidence: .medium, provenance: .visualEstimate),
                NutrientValue(identifier: .fat, value: fat, unit: .gram, confidence: .medium, provenance: .visualEstimate),
                NutrientValue(identifier: .fiber, value: fiber, unit: .gram, confidence: .medium, provenance: .visualEstimate),
            ]
        )
        return Meal(timestamp: timestamp, analysisState: state, activeRevisionID: revision.id, analysisRevisions: [revision])
    }

    private func nutritionGoals(from date: Date) -> [NutritionGoalPeriod] {
        [
            NutritionGoalPeriod(validFrom: date, nutrientIdentifier: .energy, targetValue: 2_200, unit: .kilocalorie),
            NutritionGoalPeriod(validFrom: date, nutrientIdentifier: .protein, targetValue: 130, unit: .gram),
            NutritionGoalPeriod(validFrom: date, nutrientIdentifier: .carbohydrates, targetValue: 240, unit: .gram),
            NutritionGoalPeriod(validFrom: date, nutrientIdentifier: .fat, targetValue: 75, unit: .gram),
            NutritionGoalPeriod(validFrom: date, nutrientIdentifier: .fiber, targetValue: 30, unit: .gram),
        ]
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

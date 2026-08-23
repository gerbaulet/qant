import Foundation
import Testing
@testable import quantified_self

@MainActor
struct MealHistoryBuilderTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "de_DE")
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    @Test("Meals are grouped by local day and sorted newest first")
    func dayGrouping() {
        let breakfast = meal(at: date(2026, 8, 22, 8), category: .breakfast, energy: 420)
        let dinner = meal(at: date(2026, 8, 22, 19), category: .dinner, energy: 780)
        let nextDay = meal(at: date(2026, 8, 23, 12), category: .lunch, energy: 650)

        let sections = MealHistoryBuilder.makeSections(
            meals: [breakfast, nextDay, dinner],
            grouping: .day,
            calendar: calendar
        )

        #expect(sections.count == 2)
        #expect(sections[0].entries.map(\.id) == [nextDay.id])
        #expect(sections[1].entries.map(\.id) == [dinner.id, breakfast.id])
        #expect(sections[1].entries.first?.category == .dinner)
        #expect(sections[1].entries.first?.energyKilocalories == 780)
    }

    @Test("Week and month grouping use calendar intervals and exclude archived meals")
    func broaderGrouping() {
        let augustFirst = meal(at: date(2026, 8, 3, 12), category: .lunch, energy: 500)
        let augustSecond = meal(at: date(2026, 8, 8, 12), category: .lunch, energy: 600)
        let september = meal(at: date(2026, 9, 1, 12), category: .lunch, energy: 700)
        let archived = meal(at: date(2026, 9, 2, 12), category: .lunch, energy: 900)
        archived.mealState = .archived

        let weekSections = MealHistoryBuilder.makeSections(
            meals: [augustFirst, augustSecond, september, archived],
            grouping: .week,
            calendar: calendar
        )
        let monthSections = MealHistoryBuilder.makeSections(
            meals: [augustFirst, augustSecond, september, archived],
            grouping: .month,
            calendar: calendar
        )

        #expect(weekSections.count == 2)
        #expect(weekSections[1].entries.count == 2)
        #expect(monthSections.count == 2)
        #expect(monthSections[1].entries.count == 2)
        #expect(monthSections.flatMap(\.entries).contains { $0.id == archived.id } == false)
    }

    private func meal(
        at timestamp: Date,
        category: MealCategory,
        energy: Double
    ) -> Meal {
        let revision = MealAnalysisRevision(
            modelIdentifier: "test/model",
            status: .confirmed,
            mealName: "Testmahlzeit",
            confidence: .medium,
            nutrients: [NutrientValue(
                identifier: .energy,
                value: energy,
                unit: .kilocalorie,
                confidence: .medium,
                provenance: .visualEstimate
            )]
        )
        return Meal(
            timestamp: timestamp,
            category: category,
            analysisState: .confirmed,
            activeRevisionID: revision.id,
            analysisRevisions: [revision]
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour
        ))!
    }
}

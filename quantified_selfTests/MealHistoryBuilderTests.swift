import Foundation
import Testing
@testable import Quant

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
        #expect(sections[1].entries.first?.energyKilocalories == 780)
        #expect(sections[0].totalEnergyKilocalories == 650)
        #expect(sections[1].totalEnergyKilocalories == 1_200)
        #expect(sections.allSatisfy { !$0.containsProvisionalEnergy })
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
        #expect(monthSections[1].totalEnergyKilocalories == 1_100)
        #expect(monthSections.flatMap(\.entries).contains { $0.id == archived.id } == false)
    }

    @Test("Section totals identify provisional energy")
    func provisionalSectionTotal() {
        let confirmed = meal(at: date(2026, 8, 22, 8), category: .breakfast, energy: 420)
        let provisional = meal(
            at: date(2026, 8, 22, 12),
            category: .lunch,
            energy: 610,
            status: .awaitingConfirmation
        )

        let section = MealHistoryBuilder.makeSections(
            meals: [confirmed, provisional],
            grouping: .day,
            calendar: calendar
        ).first

        #expect(section?.totalEnergyKilocalories == 1_030)
        #expect(section?.containsProvisionalEnergy == true)
    }

    @Test("History uses validated call calories when the nutrient relationship is missing")
    func callMetadataFallback() {
        let revision = MealAnalysisRevision(
            modelIdentifier: "test/model",
            providerMetadata: InitialAnalysisRunMetadata.encodeCalls([
                AnalysisCallSummary(
                    callNumber: 1,
                    sampleNumber: nil,
                    attemptNumber: 1,
                    status: .succeeded,
                    modelIdentifier: "test/model",
                    providerIdentifier: "Test",
                    energyKilocalories: 483,
                    errorMessage: nil
                ),
            ]),
            trigger: .correction,
            status: .confirmed,
            mealName: "Kuchenstücke mit Schlagsahne",
            confidence: .medium
        )
        let meal = Meal(
            timestamp: date(2026, 8, 23, 12),
            analysisState: .confirmed,
            activeRevisionID: revision.id,
            analysisRevisions: [revision]
        )

        let section = MealHistoryBuilder.makeSections(
            meals: [meal],
            grouping: .day,
            calendar: calendar
        ).first

        #expect(section?.entries.first?.energyKilocalories == 483)
        #expect(section?.totalEnergyKilocalories == 483)
    }

    @Test("Search matches the current meal name, components, and user comment")
    func searchContent() {
        let curry = meal(
            at: date(2026, 8, 22, 12),
            category: .lunch,
            energy: 650,
            name: "Hähnchen-Curry",
            comment: "Große Portion",
            componentNames: ["Basmatireis", "Kokossoße"]
        )
        let soup = meal(
            at: date(2026, 8, 21, 19),
            category: .dinner,
            energy: 430,
            name: "Tomatensuppe"
        )

        #expect(search("hahn", in: [curry, soup]) == [curry.id])
        #expect(search("REIS", in: [curry, soup]) == [curry.id])
        #expect(search("große", in: [curry, soup]) == [curry.id])
        #expect(search("tomaten", in: [curry, soup]) == [soup.id])
    }

    @Test("Search uses only the active revision and does not match meal categories")
    func searchScope() {
        let meal = meal(
            at: date(2026, 8, 22, 12),
            category: .breakfast,
            energy: 650,
            name: "Aktueller Name"
        )
        meal.analysisRevisions.append(MealAnalysisRevision(
            modelIdentifier: "test/model",
            status: .confirmed,
            mealName: "Früherer Name",
            confidence: .medium
        ))

        #expect(search("aktuell", in: [meal]) == [meal.id])
        #expect(search("früher", in: [meal]).isEmpty)
        #expect(search("frühstück", in: [meal]).isEmpty)
    }

    @Test("Search keeps grouping and removes empty sections")
    func searchGrouping() {
        let august = meal(
            at: date(2026, 8, 22, 12),
            category: .lunch,
            energy: 650,
            name: "Curry"
        )
        let september = meal(
            at: date(2026, 9, 2, 12),
            category: .lunch,
            energy: 500,
            name: "Suppe"
        )

        let sections = MealHistoryBuilder.makeSections(
            meals: [august, september],
            grouping: .month,
            calendar: calendar,
            searchQuery: "Curry"
        )

        #expect(sections.count == 1)
        #expect(sections.first?.entries.map(\.id) == [august.id])
    }

    @Test("Whitespace search keeps all meals and multiple terms must all match")
    func searchTerms() {
        let curry = meal(
            at: date(2026, 8, 22, 12),
            category: .lunch,
            energy: 650,
            name: "Hähnchen-Curry",
            componentNames: ["Basmatireis"]
        )
        let soup = meal(
            at: date(2026, 8, 21, 19),
            category: .dinner,
            energy: 430,
            name: "Tomatensuppe"
        )

        #expect(search("  \n ", in: [curry, soup]) == [curry.id, soup.id])
        #expect(search("curry reis", in: [curry, soup]) == [curry.id])
        #expect(search("curry tomate", in: [curry, soup]).isEmpty)
    }

    private func meal(
        at timestamp: Date,
        category: MealCategory,
        energy: Double,
        status: AnalysisState = .confirmed,
        name: String = "Testmahlzeit",
        comment: String? = nil,
        componentNames: [String] = []
    ) -> Meal {
        let revision = MealAnalysisRevision(
            modelIdentifier: "test/model",
            status: status,
            mealName: name,
            confidence: .medium,
            components: componentNames.enumerated().map { index, name in
                FoodComponent(sortIndex: index, name: name)
            },
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
            userComment: comment,
            category: category,
            analysisState: status,
            activeRevisionID: revision.id,
            analysisRevisions: [revision]
        )
    }

    private func search(_ query: String, in meals: [Meal]) -> [UUID] {
        MealHistoryBuilder.makeSections(
            meals: meals,
            grouping: .day,
            calendar: calendar,
            searchQuery: query
        ).flatMap(\.entries).map(\.id)
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

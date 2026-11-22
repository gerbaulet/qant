import Foundation
import Testing
@testable import Quant

@MainActor
struct EnergyBalanceBuilderTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    @Test("Balance subtracts active and resting energy from intake")
    func calculatesBalance() throws {
        let day = date(2026, 11, 10, 12)
        let balance = EnergyBalanceBuilder.makeBalance(
            for: day,
            meals: [meal(at: day, state: .confirmed, energy: 1_760)],
            expenditure: DailyEnergyExpenditure(
                date: day,
                activeKilocalories: 570,
                restingKilocalories: 1_610
            ),
            now: date(2026, 11, 11, 12),
            calendar: calendar
        )

        #expect(balance.intakeKilocalories == 1_760)
        #expect(balance.expenditureKilocalories == 2_180)
        #expect(balance.balanceKilocalories == -420)
        #expect(balance.completeness == .complete)
        #expect(!balance.isCurrentDay)
    }

    @Test("An unlogged day remains missing instead of becoming zero intake")
    func missingIntake() {
        let day = date(2026, 11, 10, 12)
        let balance = EnergyBalanceBuilder.makeBalance(
            for: day,
            meals: [],
            expenditure: DailyEnergyExpenditure(
                date: day,
                activeKilocalories: 400,
                restingKilocalories: 1_600
            ),
            now: date(2026, 11, 11, 12),
            calendar: calendar
        )

        #expect(balance.intakeKilocalories == nil)
        #expect(balance.balanceKilocalories == nil)
        #expect(balance.completeness == .missingIntake)
    }

    @Test("A pending meal without an estimate remains missing instead of becoming zero")
    func pendingMealWithoutEstimate() {
        let day = date(2026, 11, 10, 12)
        let balance = EnergyBalanceBuilder.makeBalance(
            for: day,
            meals: [meal(at: day, state: .analyzing, energy: 2_000)],
            expenditure: DailyEnergyExpenditure(
                date: day,
                activeKilocalories: 400,
                restingKilocalories: 1_600
            ),
            now: date(2026, 11, 11, 12),
            calendar: calendar
        )

        #expect(balance.intakeKilocalories == nil)
        #expect(balance.balanceKilocalories == nil)
        #expect(balance.completeness == .missingIntake)
    }

    @Test("Missing health components never produce a total")
    func missingHealthComponent() {
        let day = date(2026, 11, 10, 12)
        let balance = EnergyBalanceBuilder.makeBalance(
            for: day,
            meals: [meal(at: day, state: .confirmed, energy: 2_000)],
            expenditure: DailyEnergyExpenditure(
                date: day,
                activeKilocalories: 500,
                restingKilocalories: nil
            ),
            now: date(2026, 11, 11, 12),
            calendar: calendar
        )

        #expect(balance.expenditureKilocalories == nil)
        #expect(balance.balanceKilocalories == nil)
        #expect(balance.completeness == .missingRestingEnergy)
    }

    @Test("Known gaps in resting energy make the balance incomplete")
    func incompleteRestingEnergyCoverage() {
        let day = date(2026, 11, 10, 12)
        let coverage = RestingEnergyCoverage(
            expectedDuration: 24 * 60 * 60,
            primaryDuration: 20 * 60 * 60,
            iPhoneFallbackDuration: 2 * 60 * 60
        )
        let balance = EnergyBalanceBuilder.makeBalance(
            for: day,
            meals: [meal(at: day, state: .confirmed, energy: 2_000)],
            expenditure: DailyEnergyExpenditure(
                date: day,
                activeKilocalories: 400,
                restingKilocalories: 1_500,
                restingEnergyCoverage: coverage
            ),
            now: date(2026, 11, 11, 12),
            calendar: calendar
        )

        #expect(balance.completeness == .incompleteRestingEnergy)
        #expect(balance.restingEnergyCoverage == coverage)
    }

    @Test("A complete iPhone fallback remains an evaluable balance")
    func completeIPhoneFallback() {
        let day = date(2026, 11, 10, 12)
        let coverage = RestingEnergyCoverage(
            expectedDuration: 24 * 60 * 60,
            primaryDuration: 16 * 60 * 60,
            iPhoneFallbackDuration: 8 * 60 * 60
        )
        let balance = EnergyBalanceBuilder.makeBalance(
            for: day,
            meals: [meal(at: day, state: .confirmed, energy: 2_000)],
            expenditure: DailyEnergyExpenditure(
                date: day,
                activeKilocalories: 400,
                restingKilocalories: 1_500,
                restingEnergyCoverage: coverage
            ),
            now: date(2026, 11, 11, 12),
            calendar: calendar
        )

        #expect(balance.completeness == .complete)
        #expect(balance.restingEnergyCoverage?.usesIPhoneFallback == true)
    }

    @Test("Open meal analyses make the balance provisional")
    func provisionalMeal() {
        let day = date(2026, 11, 10, 12)
        let balance = EnergyBalanceBuilder.makeBalance(
            for: day,
            meals: [
                meal(at: day, state: .confirmed, energy: 1_000),
                meal(at: date(2026, 11, 10, 18), state: .needsClarification, energy: 700),
            ],
            expenditure: DailyEnergyExpenditure(
                date: day,
                activeKilocalories: 400,
                restingKilocalories: 1_600
            ),
            now: date(2026, 11, 11, 12),
            calendar: calendar
        )

        #expect(balance.intakeKilocalories == 1_700)
        #expect(balance.balanceKilocalories == -300)
        #expect(balance.completeness == .provisionalIntake)
    }

    @Test("Daily iteration follows calendar boundaries across daylight saving time")
    func daylightSavingDays() {
        let start = date(2026, 3, 28)
        let end = date(2026, 3, 31)
        let balances = EnergyBalanceBuilder.makeBalances(
            within: DateInterval(start: start, end: end),
            meals: [],
            expenditures: [],
            now: end,
            calendar: calendar
        )

        #expect(balances.map(\.date) == [
            date(2026, 3, 28),
            date(2026, 3, 29),
            date(2026, 3, 30),
        ])
        #expect(calendar.dateComponents([.hour], from: balances[1].date, to: balances[2].date).hour == 23)
    }

    @Test("Balance trends use the same rolling day windows as nutrition trends")
    func rollingTrendIntervals() throws {
        let reference = date(2026, 8, 23, 12)

        let week = try #require(NutritionTrendsBuilder.dateInterval(
            for: reference,
            range: .week,
            calendar: calendar
        ))
        #expect(week.start == date(2026, 8, 17))
        #expect(week.end == date(2026, 8, 24))

        let month = try #require(NutritionTrendsBuilder.dateInterval(
            for: reference,
            range: .month,
            calendar: calendar
        ))
        #expect(month.start == date(2026, 7, 25))
        #expect(month.end == date(2026, 8, 24))

        let year = try #require(NutritionTrendsBuilder.dateInterval(
            for: reference,
            range: .year,
            calendar: calendar
        ))
        #expect(year.start == date(2025, 8, 24))
        #expect(year.end == date(2026, 8, 24))
    }

    @Test("Archived meals and portion adjustments follow nutrition presentation rules")
    func archivedAndAdjustedMeals() {
        let day = date(2026, 11, 10, 12)
        let adjusted = meal(at: day, state: .confirmed, energy: 600)
        adjusted.activeRevision?.portionMultiplier = 1.5
        let archived = meal(at: day, state: .confirmed, energy: 1_000)
        archived.mealState = .archived

        let balance = EnergyBalanceBuilder.makeBalance(
            for: day,
            meals: [adjusted, archived],
            expenditure: DailyEnergyExpenditure(
                date: day,
                activeKilocalories: 300,
                restingKilocalories: 1_500
            ),
            now: date(2026, 11, 11, 12),
            calendar: calendar
        )

        #expect(balance.intakeKilocalories == 900)
        #expect(balance.balanceKilocalories == -900)
    }

    private func meal(at timestamp: Date, state: AnalysisState, energy: Double) -> Meal {
        let revision = MealAnalysisRevision(
            modelIdentifier: "test/model",
            status: state,
            mealName: "Test",
            confidence: .medium,
            nutrients: [
                NutrientValue(
                    identifier: .energy,
                    value: energy,
                    unit: .kilocalorie,
                    confidence: .medium,
                    provenance: .visualEstimate
                ),
            ]
        )
        return Meal(
            timestamp: timestamp,
            analysisState: state,
            activeRevisionID: revision.id,
            analysisRevisions: [revision]
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

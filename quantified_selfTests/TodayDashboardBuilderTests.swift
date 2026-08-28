import Foundation
import Testing
@testable import Quant

@MainActor
struct TodayDashboardBuilderTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "de_DE")
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    @Test("Confirmed and provisional revisions count, pending revisions do not")
    func provisionalTotalsPolicy() {
        let today = date(2026, 8, 23, 12)
        let confirmed = meal(
            at: date(2026, 8, 23, 8),
            state: .confirmed,
            energy: 500,
            protein: 30
        )
        let provisional = meal(
            at: date(2026, 8, 23, 13),
            state: .awaitingConfirmation,
            energy: 700,
            protein: 40
        )
        let pending = meal(
            at: date(2026, 8, 23, 16),
            state: .pending,
            energy: 900,
            protein: 60
        )
        let yesterday = meal(
            at: date(2026, 8, 22, 20),
            state: .confirmed,
            energy: 1_000,
            protein: 50
        )

        let snapshot = TodayDashboardBuilder.makeSnapshot(
            for: today,
            meals: [confirmed, provisional, pending, yesterday],
            goals: goals(starting: date(2026, 8, 1)),
            calendar: calendar
        )

        #expect(snapshot.energy.consumed == 1_200)
        #expect(snapshot.energy.target == 2_200)
        #expect(snapshot.macros.first(where: { $0.id == .protein })?.consumed == 70)
        #expect(snapshot.meals.count == 3)
        #expect(snapshot.meals.first?.timestamp == pending.timestamp)
        #expect(snapshot.meals.first?.energyKilocalories == nil)
        #expect(snapshot.hasProvisionalValues)
    }

    @Test("Current-calendar day boundaries include the start and exclude the end")
    func localDayBoundaries() {
        let reference = date(2026, 3, 29, 12)
        let day = calendar.dateInterval(of: .day, for: reference)!
        let atStart = meal(at: day.start, state: .confirmed, energy: 300, protein: 10)
        let atEnd = meal(at: day.end, state: .confirmed, energy: 900, protein: 20)

        let snapshot = TodayDashboardBuilder.makeSnapshot(
            for: reference,
            meals: [atStart, atEnd],
            goals: goals(starting: date(2026, 1, 1)),
            calendar: calendar
        )

        #expect(snapshot.meals.map(\.id) == [atStart.id])
        #expect(snapshot.energy.consumed == 300)
    }

    @Test("A clarification result is visibly provisional")
    func clarificationIsProvisional() {
        let reference = date(2026, 8, 23, 12)
        let clarification = meal(
            at: reference,
            state: .needsClarification,
            energy: 650,
            protein: 25
        )

        let snapshot = TodayDashboardBuilder.makeSnapshot(
            for: reference,
            meals: [clarification],
            goals: goals(starting: date(2026, 8, 1)),
            calendar: calendar
        )

        #expect(snapshot.energy.consumed == 650)
        #expect(snapshot.meals.first?.isProvisional == true)
        #expect(snapshot.hasProvisionalValues)
    }

    @Test("Weekly progress sums intake and effective-dated daily goals")
    func weeklyProgress() {
        let reference = date(2026, 8, 19, 12)
        let monday = meal(at: date(2026, 8, 17, 12), state: .confirmed, energy: 2_000, protein: 100)
        let wednesday = meal(at: date(2026, 8, 19, 12), state: .awaitingConfirmation, energy: 1_800, protein: 90)
        let priorWeek = meal(at: date(2026, 8, 16, 12), state: .confirmed, energy: 3_000, protein: 100)
        let oldGoal = NutritionGoalPeriod(
            validFrom: date(2026, 8, 1),
            validUntil: date(2026, 8, 20),
            nutrientIdentifier: .energy,
            targetValue: 2_200,
            unit: .kilocalorie
        )
        let newGoal = NutritionGoalPeriod(
            validFrom: date(2026, 8, 20),
            nutrientIdentifier: .energy,
            targetValue: 2_100,
            unit: .kilocalorie
        )

        let snapshot = TodayDashboardBuilder.makeSnapshot(
            for: reference,
            meals: [monday, wednesday, priorWeek],
            goals: [oldGoal, newGoal],
            calendar: calendar
        )

        #expect(snapshot.weeklyEnergy.consumed == 3_800)
        #expect(snapshot.weeklyEnergy.target == 15_000)
    }

    @Test("Portion multiplier scales meal, daily and weekly nutrients")
    func portionMultiplier() {
        let reference = date(2026, 8, 23, 12)
        let adjusted = meal(
            at: reference,
            state: .confirmed,
            energy: 600,
            protein: 20,
            portionMultiplier: 1.5
        )

        let snapshot = TodayDashboardBuilder.makeSnapshot(
            for: reference,
            meals: [adjusted],
            goals: goals(starting: date(2026, 8, 1)),
            calendar: calendar
        )

        #expect(snapshot.energy.consumed == 900)
        #expect(snapshot.weeklyEnergy.consumed == 900)
        #expect(snapshot.macros.first(where: { $0.id == .protein })?.consumed == 30)
        #expect(snapshot.meals.first?.energyKilocalories == 900)
    }

    private func meal(
        at timestamp: Date,
        state: AnalysisState,
        energy: Double,
        protein: Double,
        portionMultiplier: Double = 1
    ) -> Meal {
        let nutrients = [
            NutrientValue(
                identifier: .energy,
                value: energy,
                unit: .kilocalorie,
                confidence: .medium,
                provenance: .visualEstimate
            ),
            NutrientValue(
                identifier: .protein,
                value: protein,
                unit: .gram,
                confidence: .medium,
                provenance: .visualEstimate
            ),
        ]
        let revision = MealAnalysisRevision(
            modelIdentifier: "test/model",
            status: state,
            mealName: "Testmahlzeit",
            confidence: .medium,
            nutrients: nutrients
        )
        revision.portionMultiplier = portionMultiplier
        return Meal(
            timestamp: timestamp,
            analysisState: state,
            activeRevisionID: revision.id,
            analysisRevisions: [revision]
        )
    }

    private func goals(starting start: Date) -> [NutritionGoalPeriod] {
        [
            NutritionGoalPeriod(
                validFrom: start,
                nutrientIdentifier: .energy,
                targetValue: 2_200,
                unit: .kilocalorie
            ),
            NutritionGoalPeriod(
                validFrom: start,
                nutrientIdentifier: .protein,
                targetValue: 130,
                unit: .gram
            ),
        ]
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour
        ))!
    }
}

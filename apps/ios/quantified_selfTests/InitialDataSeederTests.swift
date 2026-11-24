import Foundation
import SwiftData
import Testing
@testable import Quant

@MainActor
struct InitialDataSeederTests {
    @Test("First-run goals are effective-dated and seeding is idempotent")
    func seedsOnce() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_787_500_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        try InitialDataSeeder.seedGoalsIfNeeded(in: context, now: now, calendar: calendar)
        try InitialDataSeeder.seedGoalsIfNeeded(in: context, now: now, calendar: calendar)

        let goals = try context.fetch(FetchDescriptor<NutritionGoalPeriod>())
        #expect(goals.count == 5)
        #expect(goals.allSatisfy { $0.validFrom == calendar.startOfDay(for: now) })
        #expect(goals.first(where: { $0.nutrientIdentifier == .energy })?.targetValue == 2_200)
    }

    @Test("An existing personal target is never replaced by defaults")
    func preservesExistingGoal() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let existing = NutritionGoalPeriod(
            validFrom: Date(timeIntervalSince1970: 1_700_000_000),
            nutrientIdentifier: .energy,
            targetValue: 1_950,
            unit: .kilocalorie
        )
        context.insert(existing)
        try context.save()

        try InitialDataSeeder.seedGoalsIfNeeded(in: context)

        let goals = try context.fetch(FetchDescriptor<NutritionGoalPeriod>())
        let energyGoals = goals.filter { $0.nutrientIdentifier == .energy }
        #expect(energyGoals.count == 1)
        #expect(energyGoals.first?.targetValue == 1_950)
        #expect(goals.count == 5)
    }

    private func makeContainer() throws -> ModelContainer {
        try NutritionModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
    }
}

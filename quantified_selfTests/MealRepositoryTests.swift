import Foundation
import SwiftData
import Testing
@testable import quantified_self

@MainActor
struct MealRepositoryTests {
    @Test("Creating a meal immediately persists capture state and user input")
    func createMeal() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = SwiftDataMealRepository(context: context)
        let timestamp = Date(timeIntervalSince1970: 1_787_500_000)
        let now = Date(timeIntervalSince1970: 1_787_500_100)

        let created = try repository.createMeal(
            from: MealDraft(
                timestamp: timestamp,
                comment: "  Große Portion, etwa 350 g  ",
                category: .dinner
            ),
            now: now
        )

        let meals = try context.fetch(FetchDescriptor<Meal>())
        #expect(meals.count == 1)
        #expect(meals.first?.id == created.id)
        #expect(created.timestamp == timestamp)
        #expect(created.createdAt == now)
        #expect(created.userComment == "Große Portion, etwa 350 g")
        #expect(created.category == .dinner)
        #expect(created.mealState == .captured)
        #expect(created.analysisState == .pending)
        #expect(created.images.isEmpty)
        #expect(created.analysisRevisions.isEmpty)
    }

    @Test("Whitespace-only comments are stored as absent")
    func emptyCommentIsNil() throws {
        let container = try makeContainer()
        let repository = SwiftDataMealRepository(context: container.mainContext)

        let created = try repository.createMeal(
            from: MealDraft(
                timestamp: .now,
                comment: "  \n  ",
                category: .snack
            )
        )

        #expect(created.userComment == nil)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(NutritionSchemaV1.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: schema,
            migrationPlan: NutritionMigrationPlan.self,
            configurations: [configuration]
        )
    }
}

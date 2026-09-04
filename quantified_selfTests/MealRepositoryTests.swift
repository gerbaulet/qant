import Foundation
import SwiftData
import Testing
@testable import Quant

@MainActor
struct MealRepositoryTests {
    @Test("Creating a meal immediately persists capture state and user input")
    func createMeal() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = SwiftDataMealRepository(context: context)
        let timestamp = Date(timeIntervalSince1970: 1_787_500_000)
        let now = Date(timeIntervalSince1970: 1_787_500_100)
        let firstImage = StoredMealImage(
            id: UUID(),
            imageStorageKey: "first/image.jpg",
            thumbnailStorageKey: "first/thumbnail.jpg",
            pixelWidth: 1_600,
            pixelHeight: 1_200
        )
        let secondImage = StoredMealImage(
            id: UUID(),
            imageStorageKey: "second/image.jpg",
            thumbnailStorageKey: "second/thumbnail.jpg",
            pixelWidth: 900,
            pixelHeight: 1_200
        )

        let created = try repository.createMeal(
            from: MealDraft(
                timestamp: timestamp,
                comment: "  Große Portion, etwa 350 g  ",
                category: .dinner,
                images: [firstImage, secondImage]
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
        let images = created.images.sorted { $0.sortIndex < $1.sortIndex }
        #expect(images.count == 2)
        #expect(images[0].id == firstImage.id)
        #expect(images[0].thumbnailStorageKey == firstImage.thumbnailStorageKey)
        #expect(images[0].pixelWidth == 1_600)
        #expect(images[1].id == secondImage.id)
        #expect(images[1].sortIndex == 1)
        #expect(images.allSatisfy { $0.meal?.id == created.id })
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

    @Test("Updating a meal timestamp persists the new time and modification date")
    func updateTimestamp() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = SwiftDataMealRepository(context: context)
        let originalTimestamp = Date(timeIntervalSince1970: 1_787_500_000)
        let originalModifiedAt = Date(timeIntervalSince1970: 1_787_500_100)
        let meal = Meal(modifiedAt: originalModifiedAt, timestamp: originalTimestamp)
        context.insert(meal)
        try context.save()
        let updatedTimestamp = Date(timeIntervalSince1970: 1_787_600_000)
        let updatedAt = Date(timeIntervalSince1970: 1_787_600_100)

        try repository.updateTimestamp(updatedTimestamp, for: meal, now: updatedAt)

        context.rollback()
        let persistedMeal = try #require(context.fetch(FetchDescriptor<Meal>()).first)
        #expect(persistedMeal.timestamp == updatedTimestamp)
        #expect(persistedMeal.modifiedAt == updatedAt)
    }

    @Test("Deleting a meal persists its removal and returns its stored images")
    func deleteMeal() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = SwiftDataMealRepository(context: context)
        let image = StoredMealImage(
            id: UUID(),
            imageStorageKey: "meal/image.jpg",
            thumbnailStorageKey: "meal/thumbnail.jpg",
            pixelWidth: 800,
            pixelHeight: 600
        )
        let meal = try repository.createMeal(from: MealDraft(
            timestamp: .now,
            comment: "Delete me",
            category: .lunch,
            images: [image]
        ))

        let deletedImages = try repository.deleteMeal(meal)

        #expect(deletedImages == [image])
        #expect(try context.fetch(FetchDescriptor<Meal>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<MealImage>()).isEmpty)
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

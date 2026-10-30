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

    @Test("A quick capture waits for a description before analysis")
    func quickCaptureDescription() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = SwiftDataMealRepository(context: context)
        let capturedAt = Date(timeIntervalSince1970: 1_787_500_000)
        let describedAt = Date(timeIntervalSince1970: 1_787_500_100)
        let meal = try repository.createMeal(from: MealDraft(
            timestamp: capturedAt,
            comment: "",
            category: .lunch,
            analysisState: .awaitingDescription
        ))

        #expect(meal.analysisState == .awaitingDescription)
        #expect(meal.analysisRevisions.isEmpty)

        try repository.addDescription("  Nudeln mit Tomatensoße  ", to: meal, now: describedAt)

        context.rollback()
        let persistedMeal = try #require(context.fetch(FetchDescriptor<Meal>()).first)
        #expect(persistedMeal.userComment == "Nudeln mit Tomatensoße")
        #expect(persistedMeal.analysisState == .pending)
        #expect(persistedMeal.timestamp == capturedAt)
        #expect(persistedMeal.modifiedAt == describedAt)
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

    @Test("Duplicating a confirmed meal copies only its active result at the current time")
    func duplicateMeal() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repository = SwiftDataMealRepository(context: context)
        let sourceComponent = FoodComponent(
            sortIndex: 0,
            name: "Pasta",
            estimatedWeightGrams: 320,
            nutrients: [
                NutrientValue(
                    identifier: .energy,
                    value: 640,
                    unit: .kilocalorie,
                    confidence: .high,
                    provenance: .visualEstimate
                ),
            ]
        )
        var metadata = InitialAnalysisRunMetadata.settingPortionMultiplier(1.5, in: nil)
        metadata = InitialAnalysisRunMetadata.settingComponentMultipliers(
            [sourceComponent.id.uuidString: 0.75],
            in: metadata
        )
        let inactiveRevision = MealAnalysisRevision(
            modelIdentifier: "old/model",
            status: .confirmed,
            mealName: "Old result",
            confidence: .low
        )
        let activeRevision = MealAnalysisRevision(
            modelIdentifier: "current/model",
            providerIdentifier: "Current Provider",
            providerMetadata: metadata,
            promptVersion: 8,
            trigger: .correction,
            status: .confirmed,
            mealName: "Pasta with sauce",
            estimatedTotalWeightGrams: 400,
            confidence: .high,
            uncertaintySummary: "Sauce amount estimated",
            clarificationQuestion: "Old question?",
            clarificationAnswer: "Old answer",
            userCorrection: "More sauce",
            components: [sourceComponent],
            nutrients: [
                NutrientValue(
                    identifier: .energy,
                    value: 720,
                    unit: .kilocalorie,
                    confidence: .high,
                    provenance: .mixedEstimate
                ),
            ]
        )
        let source = Meal(
            timestamp: Date(timeIntervalSince1970: 1_787_000_000),
            userComment: "Large portion",
            category: .dinner,
            analysisState: .confirmed,
            activeRevisionID: activeRevision.id,
            clarificationCount: 1,
            analysisRevisions: [inactiveRevision, activeRevision]
        )
        context.insert(source)
        try context.save()
        let duplicatedAt = Date(timeIntervalSince1970: 1_788_000_000)
        let copiedImage = StoredMealImage(
            id: UUID(),
            imageStorageKey: "copy/image.jpg",
            thumbnailStorageKey: "copy/thumbnail.jpg",
            pixelWidth: 1_200,
            pixelHeight: 900
        )

        let duplicate = try repository.duplicateMeal(
            source,
            images: [copiedImage],
            now: duplicatedAt
        )

        #expect(duplicate.id != source.id)
        #expect(duplicate.timestamp == duplicatedAt)
        #expect(duplicate.createdAt == duplicatedAt)
        #expect(duplicate.modifiedAt == duplicatedAt)
        #expect(duplicate.userComment == source.userComment)
        #expect(duplicate.category == .dinner)
        #expect(duplicate.mealState == .captured)
        #expect(duplicate.analysisState == .confirmed)
        #expect(duplicate.clarificationCount == 0)
        #expect(duplicate.images.map(\.imageStorageKey) == [copiedImage.imageStorageKey])
        #expect(duplicate.analysisRevisions.count == 1)

        let copiedRevision = try #require(duplicate.activeRevision)
        #expect(copiedRevision.id != activeRevision.id)
        #expect(copiedRevision.createdAt == duplicatedAt)
        #expect(copiedRevision.requestDate == duplicatedAt)
        #expect(copiedRevision.status == .confirmed)
        #expect(copiedRevision.mealName == activeRevision.mealName)
        #expect(copiedRevision.modelIdentifier == activeRevision.modelIdentifier)
        #expect(copiedRevision.providerIdentifier == activeRevision.providerIdentifier)
        #expect(copiedRevision.promptVersion == activeRevision.promptVersion)
        #expect(copiedRevision.clarificationQuestion == nil)
        #expect(copiedRevision.clarificationAnswer == nil)
        #expect(copiedRevision.userCorrection == nil)
        #expect(InitialAnalysisRunMetadata.decodeCalls(copiedRevision.providerMetadata).isEmpty)
        #expect(InitialAnalysisRunMetadata.decode(copiedRevision.providerMetadata).isEmpty)
        #expect(copiedRevision.normalizedPortionMultiplier == 1.5)
        #expect(copiedRevision.nutrients.first?.value == 720)

        let copiedComponent = try #require(copiedRevision.components.first)
        #expect(copiedComponent.id != sourceComponent.id)
        #expect(copiedComponent.nutrients.first?.value == 640)
        #expect(
            InitialAnalysisRunMetadata.componentMultipliers(from: copiedRevision.providerMetadata)
                == [copiedComponent.id.uuidString: 0.75]
        )
    }

    @Test("Only confirmed meals with a confirmed active result can be duplicated")
    func duplicateMealEligibility() throws {
        let container = try makeContainer()
        let repository = SwiftDataMealRepository(context: container.mainContext)
        let revision = MealAnalysisRevision(
            modelIdentifier: "model",
            status: .awaitingConfirmation,
            mealName: "Result",
            confidence: .medium
        )
        let meal = Meal(
            analysisState: .awaitingConfirmation,
            activeRevisionID: revision.id,
            analysisRevisions: [revision]
        )
        container.mainContext.insert(meal)
        try container.mainContext.save()

        #expect(!meal.canBeDuplicated)
        #expect(throws: MealDuplicationError.self) {
            try repository.duplicateMeal(meal, images: [], now: .now)
        }
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

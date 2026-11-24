import Foundation
import SwiftData
import Testing
@testable import Quant

@MainActor
struct PersistenceModelTests {
    @Test("An analysis appended to an existing meal keeps its calories after reopening the store")
    func appendedAnalysisGraphRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "quant-analysis-round-trip-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "Nutrition.store")
        let mealID = UUID()

        do {
            let schema = Schema(NutritionSchemaV2.models)
            let configuration = ModelConfiguration(
                "AnalysisRoundTrip",
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(
                for: schema,
                migrationPlan: NutritionMigrationPlan.self,
                configurations: [configuration]
            )
            let context = container.mainContext
            let meal = Meal(id: mealID)
            context.insert(meal)
            try context.save()

            let revision = MealAnalysisRevision(
                modelIdentifier: "example/model",
                providerMetadata: InitialAnalysisRunMetadata.encodeCalls([
                    AnalysisCallSummary(
                        callNumber: 1,
                        sampleNumber: 1,
                        attemptNumber: 1,
                        status: .succeeded,
                        modelIdentifier: "example/model",
                        providerIdentifier: "Example",
                        energyKilocalories: 640,
                        errorMessage: nil
                    ),
                ]),
                status: .confirmed,
                mealName: "Test meal",
                confidence: .medium,
                components: [
                    FoodComponent(
                        sortIndex: 0,
                        name: "Test component",
                        estimatedWeightGrams: 250,
                        nutrients: [
                            NutrientValue(
                                identifier: .energy,
                                value: 640,
                                unit: .kilocalorie,
                                confidence: .medium,
                                provenance: .visualEstimate
                            ),
                        ]
                    ),
                ],
                nutrients: [
                    NutrientValue(
                        identifier: .energy,
                        value: 640,
                        unit: .kilocalorie,
                        confidence: .medium,
                        provenance: .visualEstimate
                    ),
                ]
            )
            meal.analysisRevisions.append(revision)
            meal.activeRevisionID = revision.id
            meal.analysisState = .confirmed
            try context.save()
        }

        let schema = Schema(NutritionSchemaV2.models)
        let configuration = ModelConfiguration(
            "AnalysisRoundTrip",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let reopened = try ModelContainer(
            for: schema,
            migrationPlan: NutritionMigrationPlan.self,
            configurations: [configuration]
        )
        let meal = try #require(
            reopened.mainContext.fetch(FetchDescriptor<Meal>()).first { $0.id == mealID }
        )

        #expect(meal.activeRevision?.nutrients.first?.value == 640)
        #expect(meal.activeRevision?.components.first?.name == "Test component")
        #expect(meal.activeRevision?.components.first?.nutrients.first?.value == 640)
        #expect(meal.activeRevision?.normalizedPortionMultiplier == 1)
        #expect(InitialAnalysisRunMetadata.decodeCalls(meal.activeRevision?.providerMetadata).first?.energyKilocalories == 640)
    }

    @Test("Version 1 stores migrate without losing meals")
    func versionOneMigration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "quant-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "Nutrition.store")

        do {
            let schema = Schema(NutritionSchemaV1.models)
            let configuration = ModelConfiguration(
                "MigrationTest",
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            container.mainContext.insert(Meal(userComment: "Bleibt erhalten"))
            try container.mainContext.save()
        }

        let schema = Schema(NutritionSchemaV2.models)
        let configuration = ModelConfiguration(
            "MigrationTest",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let migrated = try ModelContainer(
            for: schema,
            migrationPlan: NutritionMigrationPlan.self,
            configurations: [configuration]
        )

        #expect(try migrated.mainContext.fetch(FetchDescriptor<Meal>()).first?.userComment == "Bleibt erhalten")
        #expect(try migrated.mainContext.fetch(FetchDescriptor<PendingMealAnalysis>()).isEmpty)
    }

    @Test("Meal revisions and nutrients survive an in-memory SwiftData save")
    func modelGraphRoundTrip() throws {
        let container = try NutritionModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext

        let energy = NutrientValue(
            identifier: .energy,
            value: 785,
            unit: .kilocalorie,
            confidence: .medium,
            provenance: .mixedEstimate
        )
        let revision = MealAnalysisRevision(
            modelIdentifier: "example/model",
            status: .awaitingConfirmation,
            mealName: "Chicken Curry mit Reis",
            confidence: .medium,
            nutrients: [energy]
        )
        revision.portionMultiplier = 1.7
        let meal = Meal(
            timestamp: Date(timeIntervalSince1970: 1_787_500_000),
            userComment: "Etwa 440 g",
            category: .dinner,
            analysisState: .awaitingConfirmation,
            activeRevisionID: revision.id,
            analysisRevisions: [revision]
        )

        context.insert(meal)
        try context.save()
        context.rollback()

        let fetchedMeals = try context.fetch(FetchDescriptor<Meal>())
        #expect(fetchedMeals.count == 1)
        #expect(fetchedMeals.first?.activeRevision?.mealName == "Chicken Curry mit Reis")
        #expect(fetchedMeals.first?.activeRevision?.nutrients.first?.value == 785)
        #expect(fetchedMeals.first?.activeRevision?.portionMultiplier == 1.7)

        fetchedMeals.first?.activeRevision?.portionMultiplier = 5
        #expect(fetchedMeals.first?.activeRevision?.portionMultiplier == 4)
        #expect(fetchedMeals.first?.activeRevision?.normalizedPortionMultiplier == 4)
    }

    @Test("CloudKit mode can validate the full schema without contacting iCloud")
    func cloudSchemaValidation() throws {
        let container = try NutritionModelContainerFactory.makeContainer(
            mode: .cloudKit,
            isStoredInMemoryOnly: true
        )
        #expect(container.mainContext.container === container)
    }

    @Test("Readiness audit keeps capability and file-backed photo blockers explicit")
    func cloudReadinessAudit() {
        #expect(CloudSyncReadinessAudit.issues(
            mode: .local,
            containsFileBackedImages: true
        ) == [.capabilityNotEnabled, .fileBackedImagesNeedCloudAssetStorage])
        #expect(CloudSyncReadinessAudit.issues(
            mode: .cloudKit,
            containsFileBackedImages: false
        ).isEmpty)
    }

    @Test("Cloud readiness image lookup only needs to detect existence")
    func cloudReadinessImageLookup() throws {
        let container = try NutritionModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext

        #expect(try !CloudSyncReadinessImageLookup.containsImages(in: context))
        context.insert(MealImage(
            sortIndex: 0,
            imageStorageKey: "meal/image.jpg",
            thumbnailStorageKey: "meal/thumbnail.jpg",
            pixelWidth: 800,
            pixelHeight: 600
        ))
        try context.save()

        #expect(try CloudSyncReadinessImageLookup.containsImages(in: context))
    }
}

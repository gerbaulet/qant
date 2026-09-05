import Foundation
import SwiftData
import Testing
@testable import Quant

@MainActor
struct PersistenceModelTests {
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
    }

    @Test("Dinner suggestions, ingredients and per-serving nutrients survive a save")
    func dinnerSuggestionRoundTrip() throws {
        let container = try NutritionModelContainerFactory.makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let suggestion = DinnerSuggestion(
            sortIndex: 0,
            name: "Linsenpfanne",
            fitSummary: "Passt zum offenen Proteinbudget.",
            ingredients: [DinnerSuggestionIngredient(sortIndex: 0, name: "Linsen", amount: 400, unit: "g")],
            nutrients: [DinnerSuggestionNutrient(identifier: .energy, valuePerServing: 610, unit: .kilocalorie)]
        )
        let batch = DinnerSuggestionBatch(
            portionCount: 4,
            availableIngredients: "Spinat",
            preferenceSummary: "Vegetarisch",
            modelIdentifier: "example/model",
            hasProvisionalInput: true,
            hadNoEnergyRoom: false,
            energyRemaining: 600,
            proteinRemaining: 45,
            carbohydratesRemaining: 60,
            fatRemaining: 20,
            fiberRemaining: 15,
            suggestions: [suggestion]
        )

        context.insert(batch)
        try context.save()
        context.rollback()

        let fetched = try #require(context.fetch(FetchDescriptor<DinnerSuggestionBatch>()).first)
        #expect(fetched.portionCount == 4)
        #expect(fetched.suggestions.first?.ingredients.first?.name == "Linsen")
        #expect(fetched.suggestions.first?.nutrients.first?.valuePerServing == 610)
    }

    @Test("V1 stores migrate to V2 without losing existing meals")
    func migratesV1Store() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "qant-v1-v2-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "nutrition.store")

        do {
            let schema = Schema(NutritionSchemaV1.models)
            let configuration = ModelConfiguration(
                "MigrationTest",
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            container.mainContext.insert(Meal(
                timestamp: Date(timeIntervalSince1970: 1_787_500_000),
                category: .dinner
            ))
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

        let meals = try migrated.mainContext.fetch(FetchDescriptor<Meal>())
        #expect(meals.count == 1)
        #expect(try migrated.mainContext.fetch(FetchDescriptor<DinnerSuggestionBatch>()).isEmpty)
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
}

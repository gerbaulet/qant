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

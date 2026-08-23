import Foundation
import SwiftData
import Testing
@testable import quantified_self

@MainActor
struct PersistenceModelTests {
    @Test("Meal revisions and nutrients survive an in-memory SwiftData save")
    func modelGraphRoundTrip() throws {
        let schema = Schema(NutritionSchemaV1.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: NutritionMigrationPlan.self,
            configurations: [configuration]
        )
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
    }
}

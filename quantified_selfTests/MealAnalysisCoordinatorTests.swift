import Foundation
import SwiftData
import Testing
@testable import quantified_self

@MainActor
struct MealAnalysisCoordinatorTests {
    @Test("Successful analysis persists a complete active revision")
    func persistsSuccessfulAnalysis() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let image = MealImage(
            sortIndex: 0,
            imageStorageKey: "meal/image.jpg",
            thumbnailStorageKey: "meal/thumbnail.jpg",
            pixelWidth: 1_000,
            pixelHeight: 800
        )
        let meal = Meal(userComment: "Große Portion", images: [image])
        context.insert(meal)
        try context.save()
        let provider = AnalysisProviderStub(result: NutritionAnalysisValidatorTests.validResult())
        let storage = AnalysisImageStorage(dataByKey: ["meal/image.jpg": Data([7, 8, 9])])
        let now = Date(timeIntervalSince1970: 1_787_600_000)
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: storage,
            now: { now }
        )

        await coordinator.analyze(meal)

        #expect(meal.analysisState == .awaitingConfirmation)
        #expect(meal.activeRevision?.mealName == "Gemüsecurry mit Reis")
        #expect(meal.activeRevision?.modelIdentifier == "example/vision-model")
        #expect(meal.activeRevision?.nutrients.count == 8)
        #expect(meal.activeRevision?.status == .awaitingConfirmation)
        #expect(provider.receivedRequest?.userComment == "Große Portion")
        #expect(provider.receivedRequest?.images.first?.data == Data([7, 8, 9]))
    }

    @Test("A material clarification question changes the persisted state")
    func persistsClarificationState() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let meal = Meal(analysisState: .failed)
        context.insert(meal)
        try context.save()
        let provider = AnalysisProviderStub(result: NutritionAnalysisValidatorTests.validResult(
            clarificationQuestion: "Wie viel Dressing wurde verwendet?"
        ))
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:])
        )

        await coordinator.analyze(meal)

        #expect(meal.analysisState == .needsClarification)
        #expect(meal.activeRevision?.clarificationQuestion == "Wie viel Dressing wurde verwendet?")
    }

    @Test("Provider failures preserve the meal and expose a retryable failed state")
    func preservesMealOnFailure() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let meal = Meal(userComment: "Bleibt gespeichert")
        context.insert(meal)
        try context.save()
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: AnalysisProviderStub(error: OpenRouterClientError.serverError),
            imageStorage: AnalysisImageStorage(dataByKey: [:])
        )

        await coordinator.analyze(meal)

        #expect(meal.analysisState == .failed)
        #expect(meal.userComment == "Bleibt gespeichert")
        #expect(meal.analysisRevisions.isEmpty)
        #expect(try context.fetch(FetchDescriptor<Meal>()).count == 1)
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

@MainActor
private final class AnalysisProviderStub: NutritionAnalysisProviding {
    let result: NutritionAnalysisResult?
    let error: Error?
    var receivedRequest: NutritionAnalysisRequest?

    init(result: NutritionAnalysisResult) {
        self.result = result
        self.error = nil
    }

    init(error: Error) {
        self.result = nil
        self.error = error
    }

    func analyze(_ request: NutritionAnalysisRequest) async throws -> NutritionAnalysisResult {
        receivedRequest = request
        if let error { throw error }
        return result!
    }
}

private struct AnalysisImageStorage: ImageStorageProviding {
    let dataByKey: [String: Data]

    func storeImageData(_ data: Data, id: UUID) async throws -> StoredMealImage {
        throw ImageStorageError.encodingFailed
    }

    func data(forStorageKey storageKey: String) async throws -> Data {
        guard let data = dataByKey[storageKey] else { throw ImageStorageError.invalidStorageKey }
        return data
    }

    func deleteImage(_ image: StoredMealImage) async {}
}

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
        #expect(provider.requestCount == 3)
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

    @Test("Confirmation finalizes only the active awaiting revision")
    func confirmsActiveRevision() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let revision = makeRevision(status: .awaitingConfirmation)
        let meal = Meal(
            analysisState: .awaitingConfirmation,
            activeRevisionID: revision.id,
            analysisRevisions: [revision]
        )
        context.insert(meal)
        try context.save()
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: AnalysisProviderStub(error: OpenRouterClientError.serverError),
            imageStorage: AnalysisImageStorage(dataByKey: [:])
        )

        try coordinator.confirm(meal)

        #expect(meal.analysisState == .confirmed)
        #expect(revision.status == .confirmed)
    }

    @Test("A clarification answer creates a new revision with prior context")
    func answersClarificationWithRevisionHistory() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let previousRevision = makeRevision(
            status: .needsClarification,
            question: "Wie viel Dressing wurde verwendet?"
        )
        let meal = Meal(
            userComment: "Große Portion",
            analysisState: .needsClarification,
            activeRevisionID: previousRevision.id,
            analysisRevisions: [previousRevision]
        )
        context.insert(meal)
        try context.save()
        let provider = AnalysisProviderStub(result: NutritionAnalysisValidatorTests.validResult())
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:])
        )

        await coordinator.answerClarification("  Etwa zwei Esslöffel  ", for: meal)

        #expect(meal.analysisState == .awaitingConfirmation)
        #expect(meal.analysisRevisions.count == 2)
        #expect(meal.clarificationCount == 1)
        #expect(meal.activeRevision?.id != previousRevision.id)
        #expect(meal.activeRevision?.trigger == .clarification)
        #expect(meal.activeRevision?.clarificationAnswer == "Etwa zwei Esslöffel")
        #expect(provider.receivedRequest?.previousAnalysis?.mealName == "Vorherige Schätzung")
        #expect(provider.receivedRequest?.clarificationAnswer == "Etwa zwei Esslöffel")
        #expect(provider.receivedRequest?.allowsClarification == true)
    }

    @Test("Best estimate reruns without permitting another question")
    func usesBestEstimate() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let previousRevision = makeRevision(
            status: .needsClarification,
            question: "Wie viel Öl wurde verwendet?"
        )
        let meal = Meal(
            analysisState: .needsClarification,
            activeRevisionID: previousRevision.id,
            analysisRevisions: [previousRevision]
        )
        context.insert(meal)
        try context.save()
        let provider = AnalysisProviderStub(result: NutritionAnalysisValidatorTests.validResult())
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:])
        )

        await coordinator.useBestEstimate(for: meal)

        #expect(meal.activeRevision?.trigger == .bestEstimate)
        #expect(provider.receivedRequest?.requestsBestEstimate == true)
        #expect(provider.receivedRequest?.allowsClarification == false)
    }

    @Test("A correction creates a complete new revision and preserves history")
    func correctsWithRevisionHistory() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let previousRevision = makeRevision(status: .confirmed)
        let meal = Meal(
            analysisState: .confirmed,
            activeRevisionID: previousRevision.id,
            analysisRevisions: [previousRevision]
        )
        context.insert(meal)
        try context.save()
        let provider = AnalysisProviderStub(result: NutritionAnalysisValidatorTests.validResult())
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:])
        )

        await coordinator.correct("  Es waren nur 100 g Reis.  ", for: meal)

        #expect(meal.analysisState == .awaitingConfirmation)
        #expect(meal.analysisRevisions.count == 2)
        #expect(previousRevision.status == .confirmed)
        #expect(meal.activeRevision?.id != previousRevision.id)
        #expect(meal.activeRevision?.trigger == .correction)
        #expect(meal.activeRevision?.userCorrection == "Es waren nur 100 g Reis.")
        #expect(provider.receivedRequest?.previousAnalysis?.mealName == "Vorherige Schätzung")
        #expect(provider.receivedRequest?.userCorrection == "Es waren nur 100 g Reis.")
        #expect(provider.receivedRequest?.allowsClarification == false)
    }

    @Test("A failed correction remains retryable with its original text")
    func retriesFailedCorrection() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let previousRevision = makeRevision(status: .confirmed)
        let meal = Meal(
            analysisState: .confirmed,
            activeRevisionID: previousRevision.id,
            analysisRevisions: [previousRevision]
        )
        context.insert(meal)
        try context.save()
        let storage = AnalysisImageStorage(dataByKey: [:])
        let failingCoordinator = MealAnalysisCoordinator(
            context: context,
            provider: AnalysisProviderStub(error: OpenRouterClientError.serverError),
            imageStorage: storage
        )

        await failingCoordinator.correct("Es waren nur 100 g Reis.", for: meal)

        #expect(meal.analysisState == .failed)
        #expect(meal.activeRevision?.id == previousRevision.id)
        #expect(meal.analysisRevisions.count == 2)
        let failedRevision = try #require(meal.analysisRevisions.first { $0.status == .failed })
        #expect(failedRevision.trigger == .correction)
        #expect(failedRevision.userCorrection == "Es waren nur 100 g Reis.")

        let retryProvider = AnalysisProviderStub(result: NutritionAnalysisValidatorTests.validResult())
        let retryCoordinator = MealAnalysisCoordinator(
            context: context,
            provider: retryProvider,
            imageStorage: storage
        )
        await retryCoordinator.analyze(meal)

        #expect(meal.analysisState == .awaitingConfirmation)
        #expect(meal.analysisRevisions.count == 3)
        #expect(meal.activeRevision?.trigger == .correction)
        #expect(meal.activeRevision?.userCorrection == "Es waren nur 100 g Reis.")
        #expect(retryProvider.receivedRequest?.userCorrection == "Es waren nur 100 g Reis.")
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

    private func makeRevision(
        status: AnalysisState,
        question: String? = nil
    ) -> MealAnalysisRevision {
        MealAnalysisRevision(
            modelIdentifier: "example/vision-model",
            status: status,
            mealName: "Vorherige Schätzung",
            estimatedTotalWeightGrams: 450,
            confidence: .medium,
            uncertaintySummary: "Menge des Öls",
            clarificationQuestion: question,
            nutrients: NutritionAnalysisValidatorTests.coreNutrients.map { nutrient in
                NutrientValue(
                    identifier: nutrient.identifier,
                    value: nutrient.value,
                    unit: nutrient.unit,
                    confidence: nutrient.confidence,
                    provenance: nutrient.provenance
                )
            }
        )
    }
}

@MainActor
private final class AnalysisProviderStub: NutritionAnalysisProviding {
    let result: NutritionAnalysisResult?
    let error: Error?
    var receivedRequest: NutritionAnalysisRequest?
    var requestCount = 0

    init(result: NutritionAnalysisResult) {
        self.result = result
        self.error = nil
    }

    init(error: Error) {
        self.result = nil
        self.error = error
    }

    func analyze(_ request: NutritionAnalysisRequest) async throws -> NutritionAnalysisResult {
        requestCount += 1
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

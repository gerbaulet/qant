import Foundation
import SwiftData
import Testing
@testable import Quant

@MainActor
struct MealAnalysisQueueTests {
    @Test("A queued analysis is persisted until its request finishes")
    func persistsRunningAnalysis() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let meal = Meal()
        context.insert(meal)
        try context.save()
        let provider = QueueSuspendingProvider(
            result: NutritionAnalysisValidatorTests.validResult()
        )
        let queue = MealAnalysisQueue()

        let task = Task {
            await queue.analyze(
                meal,
                in: context,
                provider: provider,
                imageStorage: QueueImageStorage()
            )
        }
        while provider.requestCount == 0 { await Task.yield() }

        let pending = try context.fetch(FetchDescriptor<PendingMealAnalysis>())
        #expect(pending.count == 1)
        #expect(pending.first?.mealID == meal.id)
        #expect(pending.first?.trigger == .initial)
        #expect(meal.analysisState == .analyzing)
        #expect(MealAnalysisProgressStore.shared.analyses[meal.id] != nil)

        provider.resume()
        await task.value

        #expect(try context.fetch(FetchDescriptor<PendingMealAnalysis>()).isEmpty)
        #expect(meal.analysisState == .confirmed)
        #expect(MealAnalysisProgressStore.shared.analyses[meal.id] == nil)
    }

    @Test("App launch resumes a persisted clarification with its answer")
    func resumesPersistedClarification() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let revision = previousRevision()
        let meal = Meal(
            analysisState: .analyzing,
            activeRevisionID: revision.id,
            analysisRevisions: [revision]
        )
        let pending = PendingMealAnalysis(
            mealID: meal.id,
            trigger: .clarification,
            clarificationAnswer: "Zwei Esslöffel"
        )
        context.insert(meal)
        context.insert(pending)
        try context.save()
        let provider = QueueRecordingProvider(
            result: NutritionAnalysisValidatorTests.validResult()
        )
        let queue = MealAnalysisQueue()

        try queue.resumePendingAnalyses(
            in: context,
            provider: provider,
            imageStorage: QueueImageStorage()
        )
        while !(try context.fetch(FetchDescriptor<PendingMealAnalysis>()).isEmpty) {
            await Task.yield()
        }

        #expect(provider.receivedRequest?.clarificationAnswer == "Zwei Esslöffel")
        #expect(provider.receivedRequest?.requestGroupIdentifier == pending.id)
        #expect(meal.activeRevision?.trigger == .clarification)
        #expect(meal.activeRevision?.clarificationAnswer == "Zwei Esslöffel")
        #expect(meal.analysisState == .confirmed)
    }

    @Test("App launch creates a recoverable job for a legacy interrupted analysis")
    func resumesLegacyInterruptedAnalysis() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let meal = Meal(analysisState: .analyzing)
        context.insert(meal)
        try context.save()
        let provider = QueueRecordingProvider(
            result: NutritionAnalysisValidatorTests.validResult()
        )
        let queue = MealAnalysisQueue()

        try queue.resumePendingAnalyses(
            in: context,
            provider: provider,
            imageStorage: QueueImageStorage()
        )
        while meal.analysisState == .analyzing { await Task.yield() }

        #expect(provider.requestCount == 1)
        #expect(meal.analysisState == .confirmed)
        #expect(try context.fetch(FetchDescriptor<PendingMealAnalysis>()).isEmpty)
    }

    @Test("App launch does not reanalyze confirmed meals")
    func doesNotReanalyzeConfirmedMeals() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let revision = MealAnalysisRevision(
            modelIdentifier: "example/vision-model",
            status: .confirmed,
            mealName: "Unvollständig gespeicherte Schätzung",
            confidence: .medium
        )
        let meal = Meal(
            analysisState: .confirmed,
            activeRevisionID: revision.id,
            analysisRevisions: [revision]
        )
        context.insert(meal)
        try context.save()
        let provider = QueueRecordingProvider(
            result: NutritionAnalysisValidatorTests.validResult()
        )
        let queue = MealAnalysisQueue()

        try queue.resumePendingAnalyses(
            in: context,
            provider: provider,
            imageStorage: QueueImageStorage()
        )
        await Task.yield()

        #expect(provider.requestCount == 0)
        #expect(meal.activeRevision?.id == revision.id)
        #expect(try context.fetch(FetchDescriptor<PendingMealAnalysis>()).isEmpty)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(NutritionSchemaV2.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: schema,
            migrationPlan: NutritionMigrationPlan.self,
            configurations: [configuration]
        )
    }

    private func previousRevision() -> MealAnalysisRevision {
        MealAnalysisRevision(
            modelIdentifier: "example/vision-model",
            status: .needsClarification,
            mealName: "Vorherige Schätzung",
            estimatedTotalWeightGrams: 450,
            confidence: .medium,
            uncertaintySummary: "Menge des Öls",
            clarificationQuestion: "Wie viel Öl wurde verwendet?",
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
private final class QueueRecordingProvider: NutritionAnalysisProviding {
    let result: NutritionAnalysisResult
    private(set) var requestCount = 0
    private(set) var receivedRequest: NutritionAnalysisRequest?

    init(result: NutritionAnalysisResult) {
        self.result = result
    }

    func analyze(_ request: NutritionAnalysisRequest) async throws -> NutritionAnalysisResult {
        requestCount += 1
        receivedRequest = request
        return result
    }
}

@MainActor
private final class QueueSuspendingProvider: NutritionAnalysisProviding {
    let result: NutritionAnalysisResult
    private(set) var requestCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(result: NutritionAnalysisResult) {
        self.result = result
    }

    func analyze(_ request: NutritionAnalysisRequest) async throws -> NutritionAnalysisResult {
        await withCheckedContinuation {
            continuation = $0
            requestCount += 1
        }
        return result
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private struct QueueImageStorage: ImageStorageProviding {
    func storeImageData(_ data: Data, id: UUID) async throws -> StoredMealImage {
        throw ImageStorageError.encodingFailed
    }

    func data(forStorageKey storageKey: String) async throws -> Data {
        throw ImageStorageError.invalidStorageKey
    }

    func deleteImage(_ image: StoredMealImage) async {}
}

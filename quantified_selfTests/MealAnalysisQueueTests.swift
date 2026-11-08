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

    @Test("App launch repairs today's confirmed analyses with missing nutrients once")
    func repairsTodaysIncompleteAnalyses() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = Date(timeIntervalSince1970: 1_799_323_200)
        let todayRevision = incompleteRevision(energyKilocalories: 483)
        let today = Meal(
            timestamp: reference,
            analysisState: .confirmed,
            activeRevisionID: todayRevision.id,
            analysisRevisions: [todayRevision]
        )
        let yesterdayRevision = incompleteRevision(energyKilocalories: 585)
        let yesterday = Meal(
            timestamp: calendar.date(byAdding: .day, value: -1, to: reference)!,
            analysisState: .confirmed,
            activeRevisionID: yesterdayRevision.id,
            analysisRevisions: [yesterdayRevision]
        )
        context.insert(today)
        context.insert(yesterday)
        try context.save()
        let provider = QueueRecordingProvider(
            result: NutritionAnalysisValidatorTests.validResult()
        )
        let queue = MealAnalysisQueue()

        await queue.repairIncompleteAnalyses(
            for: reference,
            calendar: calendar,
            in: context,
            provider: provider,
            imageStorage: QueueImageStorage()
        )
        await queue.repairIncompleteAnalyses(
            for: reference,
            calendar: calendar,
            in: context,
            provider: provider,
            imageStorage: QueueImageStorage()
        )

        #expect(provider.requestCount == 1)
        #expect(provider.receivedRequest?.userCorrection == "Nährwerte vollständig neu berechnen")
        #expect(today.activeRevision?.trigger == .correction)
        #expect(today.activeRevision?.nutrients.count == 6)
        #expect(today.activeRevision?.nutrients.first { $0.knownIdentifier == .energy }?.value == 640)
        #expect(yesterday.activeRevision?.id == yesterdayRevision.id)
        #expect(try context.fetch(FetchDescriptor<PendingMealAnalysis>()).isEmpty)
    }

    @Test("App launch restores missing components for today's confirmed analyses")
    func repairsTodaysAnalysisWithoutComponents() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = Date(timeIntervalSince1970: 1_799_323_200)
        let revision = completeRevisionWithoutComponents()
        let meal = Meal(
            timestamp: reference,
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

        await queue.repairIncompleteAnalyses(
            for: reference,
            calendar: calendar,
            in: context,
            provider: provider,
            imageStorage: QueueImageStorage()
        )

        #expect(provider.requestCount == 1)
        #expect(meal.activeRevision?.trigger == .correction)
        #expect(meal.activeRevision?.components.count == 1)
        #expect(meal.activeRevision?.components.first?.nutrients.count == 6)
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

    private func incompleteRevision(energyKilocalories: Double) -> MealAnalysisRevision {
        MealAnalysisRevision(
            modelIdentifier: "example/vision-model",
            providerMetadata: InitialAnalysisRunMetadata.encodeCalls([
                AnalysisCallSummary(
                    callNumber: 1,
                    sampleNumber: nil,
                    attemptNumber: 1,
                    status: .succeeded,
                    modelIdentifier: "example/vision-model",
                    providerIdentifier: "Example",
                    energyKilocalories: energyKilocalories,
                    errorMessage: nil
                ),
            ]),
            status: .confirmed,
            mealName: "Unvollständige Schätzung",
            estimatedTotalWeightGrams: 135,
            confidence: .medium
        )
    }

    private func completeRevisionWithoutComponents() -> MealAnalysisRevision {
        let result = NutritionAnalysisValidatorTests.validResult()
        return MealAnalysisRevision(
            modelIdentifier: result.modelIdentifier,
            status: .confirmed,
            mealName: result.mealName,
            estimatedTotalWeightGrams: result.estimatedTotalWeightGrams,
            confidence: result.confidence,
            nutrients: result.nutrients.map { nutrient in
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

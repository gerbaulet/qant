import Foundation
import SwiftData
import Testing
@testable import Quant

@MainActor
struct MealAnalysisCoordinatorTests {
    @Test("Server orchestration persists its result before acknowledging the job")
    func persistsServerOperationAndAcknowledgesJob() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let image = MealImage(
            sortIndex: 0,
            imageStorageKey: "server/image.jpg",
            thumbnailStorageKey: "server/thumbnail.jpg",
            pixelWidth: 1_000,
            pixelHeight: 800
        )
        let meal = Meal(userComment: "Große Portion", images: [image])
        context.insert(meal)
        try context.save()
        let result = NutritionAnalysisValidatorTests.validResult()
        let call = AnalysisCallSummary(
            callNumber: 1,
            sampleNumber: 1,
            attemptNumber: 1,
            status: .succeeded,
            modelIdentifier: result.modelIdentifier,
            providerIdentifier: result.providerIdentifier,
            energyKilocalories: 640,
            errorMessage: nil
        )
        let provider = ServerOperationProviderStub(result: NutritionAnalysisOperationResult(
            result: result,
            calls: [call],
            promptVersion: 12,
            policyVersion: 1,
            jobIdentifier: "analysis-job-1"
        ))
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(
                dataByKey: ["server/image.jpg": Data([1, 2, 3])]
            ),
            textRecognizer: NutritionLabelTextRecognizerStub(text: ["248 kcal pro 100 g"])
        )

        await coordinator.analyze(meal)

        #expect(meal.analysisState == .confirmed)
        #expect(meal.activeRevision?.promptVersion == 12)
        #expect(InitialAnalysisRunMetadata.decodeCalls(meal.activeRevision?.providerMetadata) == [call])
        #expect(provider.legacyRequestCount == 0)
        #expect(provider.operationRequestCount == 1)
        #expect(provider.receivedTrigger == .initial)
        #expect(provider.receivedRequest?.recognizedLabelText == ["248 kcal pro 100 g"])
        #expect(provider.acknowledgedJobIdentifiers == ["analysis-job-1"])
    }

    @Test("Server analysis failures are acknowledged after preserving call history")
    func persistsServerOperationFailure() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let meal = Meal()
        context.insert(meal)
        try context.save()
        let failedCall = AnalysisCallSummary(
            callNumber: 1,
            sampleNumber: 1,
            attemptNumber: 1,
            status: .failed,
            modelIdentifier: "example/vision-model",
            providerIdentifier: nil,
            energyKilocalories: nil,
            errorMessage: "Nährwerte sind widersprüchlich."
        )
        let provider = ServerOperationProviderStub(error: NutritionAnalysisOperationFailure(
            message: "Nährwerte sind widersprüchlich.",
            calls: [failedCall],
            promptVersion: 12,
            jobIdentifier: "analysis-job-failed"
        ))
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:])
        )

        await coordinator.analyze(meal)

        #expect(meal.analysisState == .failed)
        #expect(meal.analysisRevisions.first?.promptVersion == 12)
        #expect(
            InitialAnalysisRunMetadata.decodeCalls(meal.analysisRevisions.first?.providerMetadata)
                == [failedCall]
        )
        #expect(provider.acknowledgedJobIdentifiers == ["analysis-job-failed"])
    }

    @Test("Defensive validation preserves and acknowledges the server outcome")
    func persistsDefensiveServerValidationFailure() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let meal = Meal()
        context.insert(meal)
        try context.save()
        let valid = NutritionAnalysisValidatorTests.validResult()
        let invalid = NutritionAnalysisResult(
            mealName: valid.mealName,
            estimatedTotalWeightGrams: valid.estimatedTotalWeightGrams,
            confidence: valid.confidence,
            uncertaintySummary: valid.uncertaintySummary,
            clarificationQuestion: valid.clarificationQuestion,
            nutrients: Array(valid.nutrients.dropLast()),
            components: valid.components,
            modelIdentifier: valid.modelIdentifier,
            providerIdentifier: valid.providerIdentifier
        )
        let call = AnalysisCallSummary(
            callNumber: 1,
            sampleNumber: 1,
            attemptNumber: 1,
            status: .succeeded,
            modelIdentifier: valid.modelIdentifier,
            providerIdentifier: valid.providerIdentifier,
            energyKilocalories: 640,
            errorMessage: nil
        )
        let provider = ServerOperationProviderStub(result: NutritionAnalysisOperationResult(
            result: invalid,
            calls: [call],
            promptVersion: 12,
            policyVersion: 1,
            jobIdentifier: "analysis-job-invalid"
        ))
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:])
        )

        await coordinator.analyze(meal)

        #expect(meal.analysisState == .failed)
        #expect(
            InitialAnalysisRunMetadata.decodeCalls(meal.analysisRevisions.first?.providerMetadata)
                == [call]
        )
        #expect(provider.acknowledgedJobIdentifiers == ["analysis-job-invalid"])
    }

    @Test("Successful analysis without questions is confirmed automatically")
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
        let backgroundExecutionManager = BackgroundExecutionManagerSpy()
        let now = Date(timeIntervalSince1970: 1_787_600_000)
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: storage,
            backgroundExecutionManager: backgroundExecutionManager,
            textRecognizer: NutritionLabelTextRecognizerStub(text: ["pro Scheibe 37,5 g", "248 kcal pro 100 g"]),
            now: { now }
        )

        await coordinator.analyze(meal)

        #expect(meal.analysisState == .confirmed)
        #expect(meal.activeRevision?.mealName == "Gemüsecurry mit Reis")
        #expect(meal.activeRevision?.modelIdentifier == "example/vision-model")
        #expect(meal.activeRevision?.nutrients.count == 6)
        #expect(meal.activeRevision?.status == .confirmed)
        #expect(provider.receivedRequest?.userComment == "Große Portion")
        #expect(provider.receivedRequest?.images.first?.data == Data([7, 8, 9]))
        #expect(provider.requestCount == 1)
        #expect(backgroundExecutionManager.beginCount == 1)
        #expect(backgroundExecutionManager.endedIdentifiers == [backgroundExecutionManager.identifier])
        let runs = InitialAnalysisRunMetadata.decode(meal.activeRevision?.providerMetadata)
        #expect(runs.count == 1)
        #expect(runs.map(\.runNumber) == [1])
        #expect(runs.allSatisfy { $0.modelIdentifier == "example/vision-model" })
        #expect(runs.allSatisfy { $0.energyKilocalories == 640 })
        let calls = InitialAnalysisRunMetadata.decodeCalls(meal.activeRevision?.providerMetadata)
        #expect(calls.allSatisfy { $0.requestedAt == now })
        #expect(calls.allSatisfy { $0.clarificationQuestion == nil })
        #expect(calls.allSatisfy { $0.clarificationAnswer == nil })
        #expect(provider.receivedRequest?.recognizedLabelText == ["pro Scheibe 37,5 g", "248 kcal pro 100 g"])

        context.rollback()
        let persistedMeal = try #require(context.fetch(FetchDescriptor<Meal>()).first)
        #expect(persistedMeal.activeRevision?.nutrients.first {
            $0.knownIdentifier == .energy && $0.knownUnit == .kilocalorie
        }?.value == 640)
        let persistedComponent = try #require(persistedMeal.activeRevision?.components.first)
        #expect(persistedComponent.name == "Gemüsecurry mit Reis")
        #expect(persistedComponent.estimatedWeightGrams == 480)
        #expect(persistedComponent.nutrients.count == 6)
        let dashboard = TodayDashboardBuilder.makeSnapshot(
            for: persistedMeal.timestamp,
            meals: [persistedMeal],
            goals: [],
            calendar: Calendar(identifier: .gregorian)
        )
        #expect(dashboard.energy.consumed == 640)
        #expect(dashboard.meals.first?.energyKilocalories == 640)

        persistedMeal.activeRevision?.portionMultiplier = 1.5
        #expect(persistedMeal.activeRevision?.normalizedPortionMultiplier == 1.5)
        #expect(InitialAnalysisRunMetadata.decode(persistedMeal.activeRevision?.providerMetadata) == runs)
    }

    @Test("Background execution remains active until the analysis finishes")
    func keepsBackgroundExecutionActiveDuringAnalysis() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let meal = Meal()
        context.insert(meal)
        try context.save()
        let provider = SuspendingFirstAnalysisProviderStub(
            result: NutritionAnalysisValidatorTests.validResult()
        )
        let backgroundExecutionManager = BackgroundExecutionManagerSpy()
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:]),
            backgroundExecutionManager: backgroundExecutionManager
        )

        let analysisTask = Task { await coordinator.analyze(meal) }
        while provider.requestCount < 1 {
            await Task.yield()
        }

        #expect(backgroundExecutionManager.begunNames == ["Mahlzeit analysieren"])
        #expect(backgroundExecutionManager.endedIdentifiers.isEmpty)

        provider.resumeFirstRequest()
        await analysisTask.value

        #expect(meal.analysisState == .confirmed)
        #expect(backgroundExecutionManager.endedIdentifiers == [backgroundExecutionManager.identifier])
    }

    @Test("An initial analysis makes exactly one request")
    func makesOneInitialRequest() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let meal = Meal()
        context.insert(meal)
        try context.save()
        let provider = SuspendingFirstAnalysisProviderStub(
            result: NutritionAnalysisValidatorTests.validResult()
        )
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:])
        )

        let analysisTask = Task { await coordinator.analyze(meal) }
        while provider.requestCount < 1 {
            await Task.yield()
        }
        let requestCountWhileSuspended = provider.requestCount

        provider.resumeFirstRequest()
        await analysisTask.value

        #expect(requestCountWhileSuspended == 1)
        #expect(provider.requestCount == 1)
        #expect(meal.analysisState == .confirmed)
    }

    @Test("A plate without measured quantities uses three estimates and persists the median result")
    func usesMedianForPlateWithoutMeasuredQuantities() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let image = MealImage(
            sortIndex: 0,
            imageStorageKey: "plate/image.jpg",
            thumbnailStorageKey: "plate/thumbnail.jpg",
            pixelWidth: 1_000,
            pixelHeight: 800
        )
        let meal = Meal(userComment: "Pasta mit Sauce", images: [image])
        context.insert(meal)
        try context.save()
        let provider = SequencedAnalysisProviderStub(results: [
            visualPlateResult(energy: 500, confidence: .high),
            visualPlateResult(energy: 800),
            visualPlateResult(energy: 640),
        ])
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: ["plate/image.jpg": Data([1, 2, 3])]),
            textRecognizer: NutritionLabelTextRecognizerStub(text: [""])
        )

        await coordinator.analyze(meal)

        #expect(provider.requestCount == 3)
        #expect(meal.analysisState == .confirmed)
        #expect(meal.activeRevision?.nutrients.first { $0.knownIdentifier == .energy }?.value == 640)
        let calls = InitialAnalysisRunMetadata.decodeCalls(meal.activeRevision?.providerMetadata)
        #expect(calls.map(\.sampleNumber) == [1, 2, 3])
        #expect(provider.receivedRequests.dropFirst().allSatisfy { !$0.allowsClarification })
        #expect(provider.receivedRequests.first?.independentEstimateNumber == nil)
        #expect(Set(provider.receivedRequests.dropFirst().compactMap(\.independentEstimateNumber)) == [2, 3])
    }

    @Test("A low-confidence labeled meal still uses one estimate")
    func avoidsSamplingLabeledMeal() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let image = MealImage(
            sortIndex: 0,
            imageStorageKey: "label/image.jpg",
            thumbnailStorageKey: "label/thumbnail.jpg",
            pixelWidth: 1_000,
            pixelHeight: 800
        )
        let meal = Meal(userComment: "Ein Toast", images: [image])
        context.insert(meal)
        try context.save()
        let provider = SequencedAnalysisProviderStub(results: [visualPlateResult(energy: 640)])
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: ["label/image.jpg": Data([1, 2, 3])]),
            textRecognizer: NutritionLabelTextRecognizerStub(
                text: ["Nährwerte pro 100 g Energie 248 kcal Protein 9 g"]
            )
        )

        await coordinator.analyze(meal)

        #expect(provider.requestCount == 1)
        #expect(meal.analysisState == .confirmed)
    }

    @Test("An invalid additional estimate is corrected before all three estimates are used")
    func retriesInvalidAdditionalEstimate() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let image = MealImage(
            sortIndex: 0,
            imageStorageKey: "plate/image.jpg",
            thumbnailStorageKey: "plate/thumbnail.jpg",
            pixelWidth: 1_000,
            pixelHeight: 800
        )
        let meal = Meal(userComment: "Pasta mit Sauce", images: [image])
        context.insert(meal)
        try context.save()
        let provider = SampleRetryAnalysisProviderStub(
            first: visualPlateResult(energy: 500),
            invalidSecond: resultWithEnergy(1_400),
            correctedSecond: visualPlateResult(energy: 640),
            third: visualPlateResult(energy: 800)
        )
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: ["plate/image.jpg": Data([1, 2, 3])]),
            textRecognizer: NutritionLabelTextRecognizerStub(text: [""])
        )

        await coordinator.analyze(meal)

        #expect(provider.requestCount == 4)
        #expect(meal.analysisState == .confirmed)
        #expect(meal.activeRevision?.nutrients.first { $0.knownIdentifier == .energy }?.value == 640)
        let calls = InitialAnalysisRunMetadata.decodeCalls(meal.activeRevision?.providerMetadata)
        #expect(calls.count == 4)
        #expect(calls.filter { $0.status == .failed }.count == 1)
        #expect(calls.filter { $0.status == .succeeded }.count == 3)
        #expect(calls.filter { $0.sampleNumber == 2 }.map(\.attemptNumber).sorted() == [1, 2])
        #expect(provider.repairFeedback?.contains("Kalorien und Makronährstoffe") == true)
    }

    @Test("An invalid additional estimate keeps the first valid result")
    func keepsFirstResultWhenAdditionalEstimateRemainsInvalid() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let image = MealImage(
            sortIndex: 0,
            imageStorageKey: "plate/image.jpg",
            thumbnailStorageKey: "plate/thumbnail.jpg",
            pixelWidth: 1_000,
            pixelHeight: 800
        )
        let meal = Meal(userComment: "Pasta mit Sauce", images: [image])
        context.insert(meal)
        try context.save()
        let provider = SampleRetryAnalysisProviderStub(
            first: visualPlateResult(energy: 500),
            invalidSecond: resultWithEnergy(1_400),
            correctedSecond: resultWithEnergy(1_400),
            third: visualPlateResult(energy: 800)
        )
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: ["plate/image.jpg": Data([1, 2, 3])]),
            textRecognizer: NutritionLabelTextRecognizerStub(text: [""])
        )

        await coordinator.analyze(meal)

        #expect(provider.requestCount == 4)
        #expect(meal.analysisState == .confirmed)
        #expect(meal.activeRevision?.nutrients.first { $0.knownIdentifier == .energy }?.value == 500)
        let calls = InitialAnalysisRunMetadata.decodeCalls(meal.activeRevision?.providerMetadata)
        #expect(calls.count == 4)
        #expect(calls.filter { $0.sampleNumber == 2 }.map(\.status).allSatisfy { $0 == .failed })
        #expect(calls.filter { $0.status == .succeeded }.count == 2)
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
            imageStorage: AnalysisImageStorage(dataByKey: [:]),
            retryDelaySleeper: ImmediateRetryDelaySleeper()
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
            imageStorage: AnalysisImageStorage(dataByKey: [:]),
            retryDelaySleeper: ImmediateRetryDelaySleeper()
        )

        await coordinator.analyze(meal)

        #expect(meal.analysisState == .failed)
        #expect(meal.userComment == "Bleibt gespeichert")
        #expect(meal.analysisRevisions.count == 1)
        #expect(meal.analysisRevisions.first?.status == .failed)
        #expect(meal.analysisRevisions.first?.failureMessage == "OpenRouter ist momentan nicht verfügbar.")
        let calls = InitialAnalysisRunMetadata.decodeCalls(meal.analysisRevisions.first?.providerMetadata)
        #expect(calls.count == 5)
        #expect(calls.allSatisfy { $0.status == .failed })
        #expect(calls.map(\.attemptNumber) == Array(1...5))
        #expect(try context.fetch(FetchDescriptor<Meal>()).count == 1)
    }

    @Test("A failed initial request is retried once")
    func retriesOnlyFailedInitialRequest() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let meal = Meal()
        context.insert(meal)
        try context.save()
        let valid = NutritionAnalysisValidatorTests.validResult()
        let provider = SequencedAnalysisProviderStub(outcomes: [
            .failure(OpenRouterClientError.transportFailure),
            .success(valid),
        ])
        let waiter = NetworkAvailabilityWaiterStub()
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:]),
            networkAvailabilityWaiter: waiter
        )

        await coordinator.analyze(meal)

        #expect(provider.requestCount == 2)
        #expect(waiter.waitCount == 1)
        #expect(meal.analysisState == .confirmed)
        #expect(InitialAnalysisRunMetadata.decode(meal.activeRevision?.providerMetadata).count == 1)
        let calls = InitialAnalysisRunMetadata.decodeCalls(meal.activeRevision?.providerMetadata)
        #expect(calls.count == 2)
        #expect(calls.filter { $0.status == .succeeded }.count == 1)
        #expect(calls.filter { $0.status == .failed }.count == 1)
        #expect(calls.allSatisfy { $0.sampleNumber == 1 })
        #expect(calls.map(\.attemptNumber) == [1, 2])
    }

    @Test("An invalid initial result requests one corrected result")
    func retriesOnlyInvalidInitialResult() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let meal = Meal()
        context.insert(meal)
        try context.save()
        let valid = NutritionAnalysisValidatorTests.validResult()
        let provider = SequencedAnalysisProviderStub(results: [
            invalidResult(),
            valid,
        ])
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:]),
            retryDelaySleeper: ImmediateRetryDelaySleeper()
        )

        await coordinator.analyze(meal)

        #expect(provider.requestCount == 2)
        #expect(meal.analysisState == .confirmed)
        #expect(InitialAnalysisRunMetadata.decode(meal.activeRevision?.providerMetadata).count == 1)
        #expect(provider.receivedRequests.last?.validationFeedback?.contains("widersprüchliche Werte") == true)
    }

    @Test("A timed out initial request is retried once")
    func retriesOnlyTimedOutInitialRequest() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let meal = Meal()
        context.insert(meal)
        try context.save()
        let valid = NutritionAnalysisValidatorTests.validResult()
        let provider = SequencedAnalysisProviderStub(outcomes: [
            .failure(OpenRouterClientError.timedOut),
            .success(valid),
        ])
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:]),
            retryDelaySleeper: ImmediateRetryDelaySleeper()
        )

        await coordinator.analyze(meal)

        #expect(provider.requestCount == 2)
        #expect(meal.analysisState == .confirmed)
    }

    @Test("An unreadable response is retried once")
    func retriesMalformedInitialResponses() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let meal = Meal()
        context.insert(meal)
        try context.save()
        let valid = NutritionAnalysisValidatorTests.validResult()
        let provider = SequencedAnalysisProviderStub(outcomes: [
            .failure(NutritionAnalysisError.malformedResponse),
            .success(valid),
        ])
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:])
        )

        await coordinator.analyze(meal)

        #expect(provider.requestCount == 2)
        #expect(meal.analysisState == .confirmed)
    }

    @Test("Invalid analysis values get one correction attempt")
    func retriesInvalidResults() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let meal = Meal()
        context.insert(meal)
        try context.save()
        let invalid = invalidResult()
        let valid = NutritionAnalysisValidatorTests.validResult()
        let provider = SequencedAnalysisProviderStub(results: [
            invalid, valid,
        ])
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:])
        )

        await coordinator.analyze(meal)

        #expect(provider.requestCount == 2)
        #expect(meal.analysisState == .confirmed)
        #expect(meal.analysisRevisions.count == 1)
    }

    @Test("Reported calories are not replaced by inconsistent zero-calorie components")
    func retriesComponentsThatWouldZeroReportedCalories() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let meal = Meal()
        context.insert(meal)
        try context.save()
        let provider = SequencedAnalysisProviderStub(results: [
            resultWithZeroedComponents(),
            NutritionAnalysisValidatorTests.validResult(),
        ])
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:])
        )

        await coordinator.analyze(meal)

        #expect(provider.requestCount == 2)
        #expect(meal.analysisState == .confirmed)
        #expect(meal.activeRevision?.nutrients.first { $0.knownIdentifier == .energy }?.value == 640)
        let calls = InitialAnalysisRunMetadata.decodeCalls(meal.activeRevision?.providerMetadata)
        #expect(calls.map(\.status) == [.failed, .succeeded])
        #expect(calls.map(\.energyKilocalories) == [640, 640])
        #expect(calls.first?.errorMessage?.contains("Bestandteile") == true)
    }

    @Test("Invalid analysis values fail after one correction attempt")
    func limitsInvalidResultRetries() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let meal = Meal()
        context.insert(meal)
        try context.save()
        let provider = SequencedAnalysisProviderStub(
            results: Array(repeating: invalidResult(), count: 2)
        )
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:])
        )

        await coordinator.analyze(meal)

        #expect(provider.requestCount == 2)
        #expect(meal.analysisState == .failed)
        #expect(meal.analysisRevisions.count == 1)
        #expect(meal.analysisRevisions.first?.failureMessage?.contains("Nährwert ist negativ") == true)
    }

    @Test("Offline analyses wait for connectivity before restarting")
    func waitsForNetworkBeforeRetrying() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let meal = Meal()
        context.insert(meal)
        try context.save()
        let valid = NutritionAnalysisValidatorTests.validResult()
        let provider = SequencedAnalysisProviderStub(outcomes: [
            .failure(OpenRouterClientError.transportFailure),
            .success(valid),
        ])
        let waiter = NetworkAvailabilityWaiterStub()
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:]),
            networkAvailabilityWaiter: waiter
        )

        await coordinator.analyze(meal)

        #expect(waiter.waitCount == 1)
        #expect(provider.requestCount == 2)
        #expect(meal.analysisState == .confirmed)
    }

    @Test("Offline analyses use the full transient retry budget")
    func limitsOfflineRetries() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let meal = Meal()
        context.insert(meal)
        try context.save()
        let provider = SequencedAnalysisProviderStub(outcomes: Array(
            repeating: .failure(OpenRouterClientError.networkFailure(
                code: URLError.Code.notConnectedToInternet.rawValue,
                message: "Keine Internetverbindung."
            )),
            count: 5
        ))
        let waiter = NetworkAvailabilityWaiterStub()
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:]),
            networkAvailabilityWaiter: waiter
        )

        await coordinator.analyze(meal)

        #expect(waiter.waitCount == 4)
        #expect(provider.requestCount == 5)
        #expect(meal.analysisState == .failed)
        #expect(meal.analysisRevisions.first?.failureMessage?.contains("Keine Internetverbindung.") == true)
        #expect(meal.analysisRevisions.first?.failureMessage?.contains("-1009") == true)
    }

    @Test("Legacy confirmation states finalize on app launch")
    func finalizesLegacyConfirmation() throws {
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
        try MealAnalysisCoordinator.finalizeLegacyAwaitingConfirmations(in: context)

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

        #expect(meal.analysisState == .confirmed)
        #expect(meal.analysisRevisions.count == 2)
        #expect(meal.clarificationCount == 1)
        #expect(meal.activeRevision?.id != previousRevision.id)
        #expect(meal.activeRevision?.trigger == .clarification)
        #expect(meal.activeRevision?.clarificationAnswer == "Etwa zwei Esslöffel")
        #expect(provider.receivedRequest?.previousAnalysis?.mealName == "Vorherige Schätzung")
        #expect(provider.receivedRequest?.clarificationAnswer == "Etwa zwei Esslöffel")
        #expect(provider.receivedRequest?.allowsClarification == true)
        #expect(provider.requestCount == 1)
        let calls = InitialAnalysisRunMetadata.decodeCalls(meal.activeRevision?.providerMetadata)
        #expect(calls.count == 1)
        #expect(calls.allSatisfy { $0.clarificationQuestion == "Wie viel Dressing wurde verwendet?" })
        #expect(calls.allSatisfy { $0.clarificationAnswer == "Etwa zwei Esslöffel" })
    }

    @Test("Best estimate confirms the existing revision without another request")
    func usesBestEstimate() throws {
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

        try coordinator.useBestEstimate(for: meal)

        #expect(meal.analysisState == .confirmed)
        #expect(meal.activeRevision?.id == previousRevision.id)
        #expect(meal.activeRevision?.status == .confirmed)
        #expect(meal.activeRevision?.trigger == .initial)
        #expect(meal.activeRevision?.clarificationQuestion == "Wie viel Öl wurde verwendet?")
        #expect(meal.analysisRevisions.count == 1)
        #expect(provider.requestCount == 0)
    }

    @Test("Follow-up baseline omits representative component quantities")
    func stripsComponentDetailsFromFollowUpBaseline() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let previousRevision = makeRevision(
            status: .needsClarification,
            question: "Wie groß war die Portion?"
        )
        previousRevision.components = [
            FoodComponent(
                sortIndex: 0,
                name: "Reis",
                estimatedWeightGrams: 250,
                nutrients: [
                    NutrientValue(
                        identifier: .energy,
                        value: 325,
                        unit: .kilocalorie,
                        confidence: .medium,
                        provenance: .visualEstimate
                    ),
                ]
            ),
        ]
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

        await coordinator.answerClarification("Eine große Portion", for: meal)

        let component = try #require(provider.receivedRequest?.previousAnalysis?.components.first)
        #expect(component.name == "Reis")
        #expect(component.estimatedWeightGrams == nil)
        #expect(component.nutrients.isEmpty)
        #expect(provider.receivedRequest?.previousAnalysis?.nutrients.count == 6)
    }

    @Test("A later clarification includes every earlier stored exchange")
    func includesClarificationHistory() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let first = makeRevision(status: .needsClarification, question: "Wie viel Öl?")
        first.createdAt = Date(timeIntervalSince1970: 1)
        let second = makeRevision(status: .needsClarification, question: "Wie viel Reis?")
        second.createdAt = Date(timeIntervalSince1970: 2)
        second.trigger = .clarification
        second.clarificationAnswer = "Zwei Esslöffel"
        let meal = Meal(
            analysisState: .needsClarification,
            activeRevisionID: second.id,
            clarificationCount: 1,
            analysisRevisions: [second, first]
        )
        context.insert(meal)
        try context.save()
        let provider = AnalysisProviderStub(result: NutritionAnalysisValidatorTests.validResult())
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:])
        )

        await coordinator.answerClarification("200 Gramm", for: meal)

        #expect(provider.receivedRequest?.clarificationHistory == [
            NutritionClarificationExchange(question: "Wie viel Öl?", answer: "Zwei Esslöffel"),
        ])
        #expect(provider.receivedRequest?.clarificationAnswer == "200 Gramm")
    }

    @Test("A local portion multiplier is preserved but excluded from AI baseline values")
    func keepsPortionMultiplierOutOfFollowUpBaseline() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let previousRevision = makeRevision(
            status: .needsClarification,
            question: "Wie viel Dressing?"
        )
        previousRevision.portionMultiplier = 1.5
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

        await coordinator.answerClarification("Zwei Esslöffel", for: meal)

        let baseline = try #require(provider.receivedRequest?.previousAnalysis)
        #expect(baseline.estimatedTotalWeightGrams == 450)
        #expect(baseline.nutrients.first { $0.identifier == .energy }?.value == 640)
        let revision = try #require(meal.activeRevision)
        #expect(revision.portionMultiplier == 1.5)
        #expect(revision.nutrients.first { $0.knownIdentifier == .energy }.map { revision.scaled($0.value) } == 960)
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

        #expect(meal.analysisState == .confirmed)
        #expect(meal.analysisRevisions.count == 2)
        #expect(previousRevision.status == .confirmed)
        #expect(meal.activeRevision?.id != previousRevision.id)
        #expect(meal.activeRevision?.trigger == .correction)
        #expect(meal.activeRevision?.userCorrection == "Es waren nur 100 g Reis.")
        #expect(provider.receivedRequest?.previousAnalysis?.mealName == "Vorherige Schätzung")
        #expect(provider.receivedRequest?.userCorrection == "Es waren nur 100 g Reis.")
        #expect(provider.receivedRequest?.allowsClarification == false)
    }

    @Test("A correction keeps its complete analysis graph after reopening a persistent store")
    func correctionGraphSurvivesPersistentStoreReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "quant-correction-round-trip-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "Nutrition.store")
        let mealID = UUID()

        do {
            let container = try makeContainer(at: storeURL)
            let context = container.mainContext
            let previousRevision = makeRevision(status: .confirmed)
            let meal = Meal(
                id: mealID,
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

            await coordinator.correct("Neu berechnen", for: meal)

            #expect(meal.activeRevision?.nutrients.count == 6)
            #expect(meal.activeRevision?.nutrients.first { $0.knownIdentifier == .energy }?.value == 640)
            #expect(meal.activeRevision?.components.count == 1)
            #expect(meal.activeRevision?.components.first?.nutrients.count == 6)
        }

        let reopened = try makeContainer(at: storeURL)
        let meal = try #require(
            reopened.mainContext.fetch(FetchDescriptor<Meal>()).first { $0.id == mealID }
        )
        #expect(meal.activeRevision?.trigger == .correction)
        #expect(meal.activeRevision?.nutrients.count == 6)
        #expect(meal.activeRevision?.nutrients.first { $0.knownIdentifier == .energy }?.value == 640)
        #expect(meal.activeRevision?.components.count == 1)
        #expect(meal.activeRevision?.components.first?.name == "Gemüsecurry mit Reis")
        #expect(meal.activeRevision?.components.first?.nutrients.count == 6)
    }

    @Test("An initial analysis keeps its complete graph after reopening a persistent store")
    func initialAnalysisGraphSurvivesPersistentStoreReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "quant-initial-analysis-round-trip-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "Nutrition.store")
        let mealID = UUID()

        do {
            let container = try makeContainer(at: storeURL)
            let context = container.mainContext
            let meal = Meal(id: mealID)
            context.insert(meal)
            try context.save()
            let provider = AnalysisProviderStub(result: NutritionAnalysisValidatorTests.validResult())
            let coordinator = MealAnalysisCoordinator(
                context: context,
                provider: provider,
                imageStorage: AnalysisImageStorage(dataByKey: [:])
            )

            await coordinator.analyze(meal)

            #expect(meal.activeRevision?.nutrients.count == 6)
            #expect(meal.activeRevision?.components.count == 1)
            #expect(meal.activeRevision?.components.first?.nutrients.count == 6)
        }

        let reopened = try makeContainer(at: storeURL)
        let meal = try #require(
            reopened.mainContext.fetch(FetchDescriptor<Meal>()).first { $0.id == mealID }
        )
        #expect(meal.analysisState == .confirmed)
        #expect(meal.activeRevision?.nutrients.count == 6)
        #expect(meal.activeRevision?.components.first?.name == "Gemüsecurry mit Reis")
        #expect(meal.activeRevision?.components.first?.nutrients.count == 6)
    }

    @Test("Two calorie-neutral clarifications do not drift and retain both answers")
    func keepsCaloriesStableAcrossClarifications() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let initial = makeRevision(
            status: .needsClarification,
            question: "Wie viel Öl wurde verwendet?"
        )
        let firstFollowUp = resultWithEnergy(
            640,
            uncertaintySummary: "Ölmenge wurde bestätigt",
            clarificationQuestion: "Wurde Zucker hinzugefügt?"
        )
        let finalFollowUp = resultWithEnergy(
            640,
            uncertaintySummary: "Öl- und Zuckermenge wurden bestätigt"
        )
        let provider = SequencedAnalysisProviderStub(results: [
            firstFollowUp,
            finalFollowUp,
        ])
        let meal = Meal(
            analysisState: .needsClarification,
            activeRevisionID: initial.id,
            analysisRevisions: [initial]
        )
        context.insert(meal)
        try context.save()
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:])
        )

        await coordinator.answerClarification("Ein Esslöffel", for: meal)
        #expect(meal.analysisState == .needsClarification)
        await coordinator.answerClarification("Nein", for: meal)

        #expect(provider.requestCount == 2)
        #expect(meal.analysisState == .confirmed)
        #expect(meal.clarificationCount == 2)
        #expect(meal.activeRevision?.nutrients.first { $0.knownIdentifier == .energy }?.value == 640)
        #expect(provider.receivedRequests.last?.clarificationHistory == [
            NutritionClarificationExchange(
                question: "Wie viel Öl wurde verwendet?",
                answer: "Ein Esslöffel"
            ),
        ])
        #expect(provider.receivedRequests.last?.clarificationAnswer == "Nein")
    }

    @Test("A specifically explained added amount may increase calories")
    func allowsExplainedCalorieIncrease() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let initial = makeRevision(
            status: .needsClarification,
            question: "Gab es eine zusätzliche Beilage?"
        )
        let increased = resultWithEnergy(
            800,
            uncertaintySummary: "Die bestätigte zusätzliche Brotscheibe erhöht die Energiemenge."
        )
        let provider = AnalysisProviderStub(result: increased)
        let meal = Meal(
            analysisState: .needsClarification,
            activeRevisionID: initial.id,
            analysisRevisions: [initial]
        )
        context.insert(meal)
        try context.save()
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:])
        )

        await coordinator.answerClarification("Ja, eine Scheibe Brot", for: meal)

        #expect(provider.requestCount == 1)
        #expect(meal.analysisState == .confirmed)
        #expect(meal.activeRevision?.nutrients.first { $0.knownIdentifier == .energy }?.value == 800)
        #expect(meal.activeRevision?.uncertaintySummary?.contains("Brotscheibe") == true)
    }

    @Test("An inconsistent clarification result is retried before persistence")
    func retriesInconsistentClarification() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let previousRevision = makeRevision(
            status: .needsClarification,
            question: "Wie groß war die Portion?"
        )
        let meal = Meal(
            analysisState: .needsClarification,
            activeRevisionID: previousRevision.id,
            analysisRevisions: [previousRevision]
        )
        context.insert(meal)
        try context.save()
        let provider = SequencedAnalysisProviderStub(results: [
            resultWithEnergy(3_000),
            NutritionAnalysisValidatorTests.validResult(),
        ])
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:])
        )

        await coordinator.answerClarification("Eine große Portion", for: meal)

        #expect(provider.requestCount == 2)
        #expect(meal.analysisState == .confirmed)
        #expect(meal.activeRevision?.nutrients.first { $0.knownIdentifier == .energy }?.value == 640)
    }

    @Test("An unexplained material calorie jump is retried")
    func retriesUnexplainedCalorieJump() async throws {
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
        let unexplained = resultWithEnergy(800, uncertaintySummary: nil)
        let provider = SequencedAnalysisProviderStub(results: [
            unexplained,
            NutritionAnalysisValidatorTests.validResult(),
        ])
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:])
        )

        await coordinator.answerClarification("Zwei Esslöffel", for: meal)

        #expect(provider.requestCount == 2)
        #expect(meal.analysisState == .confirmed)
        #expect(meal.activeRevision?.nutrients.first { $0.knownIdentifier == .energy }?.value == 640)
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
            imageStorage: storage,
            retryDelaySleeper: ImmediateRetryDelaySleeper()
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

        #expect(meal.analysisState == .confirmed)
        #expect(meal.analysisRevisions.count == 3)
        #expect(meal.activeRevision?.trigger == .correction)
        #expect(meal.activeRevision?.userCorrection == "Es waren nur 100 g Reis.")
        #expect(retryProvider.receivedRequest?.userCorrection == "Es waren nur 100 g Reis.")
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

    private func makeContainer(at storeURL: URL) throws -> ModelContainer {
        let schema = Schema(NutritionSchemaV2.models)
        let configuration = ModelConfiguration(
            "CorrectionRoundTrip",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
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

    private func invalidResult() -> NutritionAnalysisResult {
        let valid = NutritionAnalysisValidatorTests.validResult()
        return NutritionAnalysisResult(
            mealName: valid.mealName,
            estimatedTotalWeightGrams: valid.estimatedTotalWeightGrams,
            confidence: valid.confidence,
            uncertaintySummary: valid.uncertaintySummary,
            clarificationQuestion: valid.clarificationQuestion,
            nutrients: valid.nutrients.map { nutrient in
                AnalyzedNutrient(
                    identifier: nutrient.identifier,
                    value: nutrient.identifier == .energy ? -1 : nutrient.value,
                    unit: nutrient.unit,
                    confidence: nutrient.confidence,
                    provenance: nutrient.provenance
                )
            },
            components: valid.components,
            modelIdentifier: valid.modelIdentifier,
            providerIdentifier: valid.providerIdentifier
        )
    }

    private func resultWithEnergy(
        _ energy: Double,
        uncertaintySummary: String? = "Menge des Öls",
        clarificationQuestion: String? = nil
    ) -> NutritionAnalysisResult {
        let valid = NutritionAnalysisValidatorTests.validResult()
        let nutrients = valid.nutrients.map { nutrient in
            guard nutrient.identifier == .energy else { return nutrient }
            return AnalyzedNutrient(
                identifier: nutrient.identifier,
                value: energy,
                unit: nutrient.unit,
                confidence: nutrient.confidence,
                provenance: nutrient.provenance
            )
        }
        return NutritionAnalysisResult(
            mealName: valid.mealName,
            estimatedTotalWeightGrams: valid.estimatedTotalWeightGrams,
            confidence: valid.confidence,
            uncertaintySummary: uncertaintySummary,
            clarificationQuestion: clarificationQuestion,
            nutrients: nutrients,
            components: [AnalyzedFoodComponent(
                name: valid.mealName,
                estimatedWeightGrams: valid.estimatedTotalWeightGrams,
                nutrients: nutrients
            )],
            modelIdentifier: valid.modelIdentifier,
            providerIdentifier: valid.providerIdentifier
        )
    }

    private func resultWithZeroedComponents() -> NutritionAnalysisResult {
        let valid = NutritionAnalysisValidatorTests.validResult()
        return NutritionAnalysisResult(
            mealName: valid.mealName,
            estimatedTotalWeightGrams: valid.estimatedTotalWeightGrams,
            confidence: valid.confidence,
            uncertaintySummary: valid.uncertaintySummary,
            clarificationQuestion: nil,
            nutrients: valid.nutrients,
            components: [
                AnalyzedFoodComponent(
                    name: "Gemüsecurry mit Reis",
                    estimatedWeightGrams: valid.estimatedTotalWeightGrams,
                    nutrients: valid.nutrients.map { nutrient in
                        AnalyzedNutrient(
                            identifier: nutrient.identifier,
                            value: 0,
                            unit: nutrient.unit,
                            confidence: nutrient.confidence,
                            provenance: nutrient.provenance
                        )
                    }
                ),
            ],
            modelIdentifier: valid.modelIdentifier,
            providerIdentifier: valid.providerIdentifier
        )
    }

    private func visualPlateResult(
        energy: Double,
        confidence: EstimateConfidence = .low
    ) -> NutritionAnalysisResult {
        let nutrients = NutritionAnalysisValidatorTests.coreNutrients.map { nutrient in
            AnalyzedNutrient(
                identifier: nutrient.identifier,
                value: nutrient.identifier == .energy ? energy : nutrient.value,
                unit: nutrient.unit,
                confidence: confidence,
                provenance: .visualEstimate
            )
        }
        return NutritionAnalysisResult(
            mealName: "Pasta mit Sauce",
            estimatedTotalWeightGrams: 480,
            confidence: confidence,
            uncertaintySummary: "Die Portionsgröße ist schwer erkennbar.",
            clarificationQuestion: nil,
            nutrients: nutrients,
            components: [AnalyzedFoodComponent(
                name: "Pasta mit Sauce",
                estimatedWeightGrams: 480,
                nutrients: nutrients
            )],
            modelIdentifier: "example/vision-model",
            providerIdentifier: "Example"
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

@MainActor
private final class ServerOperationProviderStub: NutritionAnalysisOperationProviding {
    let result: NutritionAnalysisOperationResult?
    let error: Error?
    private(set) var legacyRequestCount = 0
    private(set) var operationRequestCount = 0
    private(set) var receivedRequest: NutritionAnalysisRequest?
    private(set) var receivedTrigger: AnalysisTrigger?
    private(set) var acknowledgedJobIdentifiers: [String] = []

    init(result: NutritionAnalysisOperationResult) {
        self.result = result
        self.error = nil
    }

    init(error: Error) {
        self.result = nil
        self.error = error
    }

    func analyze(_ request: NutritionAnalysisRequest) async throws -> NutritionAnalysisResult {
        legacyRequestCount += 1
        if let error { throw error }
        return result!.result
    }

    func analyzeOperation(
        _ request: NutritionAnalysisRequest,
        trigger: AnalysisTrigger,
        onStreamEvent: @escaping @MainActor (NutritionAnalysisStreamEvent) -> Void
    ) async throws -> NutritionAnalysisOperationResult {
        operationRequestCount += 1
        receivedRequest = request
        receivedTrigger = trigger
        if let error { throw error }
        return result!
    }

    func acknowledgeAnalysis(jobIdentifier: String) async throws {
        acknowledgedJobIdentifiers.append(jobIdentifier)
    }
}

@MainActor
private final class SequencedAnalysisProviderStub: NutritionAnalysisProviding {
    enum Outcome {
        case success(NutritionAnalysisResult)
        case failure(Error)
    }

    private let outcomes: [Outcome]
    private(set) var requestCount = 0
    private(set) var receivedRequests: [NutritionAnalysisRequest] = []

    init(results: [NutritionAnalysisResult]) {
        self.outcomes = results.map(Outcome.success)
    }

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func analyze(_ request: NutritionAnalysisRequest) async throws -> NutritionAnalysisResult {
        receivedRequests.append(request)
        let index = min(requestCount, outcomes.count - 1)
        requestCount += 1
        switch outcomes[index] {
        case let .success(result):
            return result
        case let .failure(error):
            throw error
        }
    }
}

@MainActor
private final class SampleRetryAnalysisProviderStub: NutritionAnalysisProviding {
    private let first: NutritionAnalysisResult
    private let invalidSecond: NutritionAnalysisResult
    private let correctedSecond: NutritionAnalysisResult
    private let third: NutritionAnalysisResult
    private(set) var requestCount = 0
    private(set) var repairFeedback: String?

    init(
        first: NutritionAnalysisResult,
        invalidSecond: NutritionAnalysisResult,
        correctedSecond: NutritionAnalysisResult,
        third: NutritionAnalysisResult
    ) {
        self.first = first
        self.invalidSecond = invalidSecond
        self.correctedSecond = correctedSecond
        self.third = third
    }

    func analyze(_ request: NutritionAnalysisRequest) async throws -> NutritionAnalysisResult {
        requestCount += 1
        switch request.independentEstimateNumber {
        case 2:
            guard let feedback = request.validationFeedback else { return invalidSecond }
            repairFeedback = feedback
            return correctedSecond
        case 3:
            return third
        default:
            return first
        }
    }
}

@MainActor
private final class SuspendingFirstAnalysisProviderStub: NutritionAnalysisProviding {
    private let result: NutritionAnalysisResult
    private var firstRequestContinuation: CheckedContinuation<Void, Never>?
    private(set) var requestCount = 0

    init(result: NutritionAnalysisResult) {
        self.result = result
    }

    func analyze(_ request: NutritionAnalysisRequest) async throws -> NutritionAnalysisResult {
        requestCount += 1
        if requestCount == 1 {
            await withCheckedContinuation { continuation in
                firstRequestContinuation = continuation
            }
        }
        return result
    }

    func resumeFirstRequest() {
        firstRequestContinuation?.resume()
        firstRequestContinuation = nil
    }
}

@MainActor
private final class NetworkAvailabilityWaiterStub: NetworkAvailabilityWaiting {
    private(set) var waitCount = 0

    func waitUntilAvailable() async throws {
        waitCount += 1
    }
}

private struct ImmediateRetryDelaySleeper: RetryDelaySleeping {
    func sleep(beforeAttempt attempt: Int) async throws {}
}

@MainActor
private final class BackgroundExecutionManagerSpy: BackgroundExecutionManaging {
    let identifier = UUID()
    private(set) var begunNames: [String] = []
    private(set) var endedIdentifiers: [UUID] = []

    var beginCount: Int { begunNames.count }

    func begin(name: String, expirationHandler: @escaping @Sendable () -> Void) -> UUID? {
        begunNames.append(name)
        return identifier
    }

    func end(_ identifier: UUID) {
        endedIdentifiers.append(identifier)
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

private struct NutritionLabelTextRecognizerStub: NutritionLabelTextRecognizing {
    let text: [String]

    nonisolated func recognizeText(in images: [NutritionAnalysisImage]) async -> [String] {
        text
    }
}

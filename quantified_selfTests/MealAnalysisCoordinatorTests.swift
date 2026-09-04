import Foundation
import SwiftData
import Testing
@testable import Quant

@MainActor
struct MealAnalysisCoordinatorTests {
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
        let now = Date(timeIntervalSince1970: 1_787_600_000)
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: storage,
            now: { now }
        )

        await coordinator.analyze(meal)

        #expect(meal.analysisState == .confirmed)
        #expect(meal.activeRevision?.mealName == "Gemüsecurry mit Reis")
        #expect(meal.activeRevision?.modelIdentifier == "example/vision-model")
        #expect(meal.activeRevision?.nutrients.count == 8)
        #expect(meal.activeRevision?.status == .confirmed)
        #expect(provider.receivedRequest?.userComment == "Große Portion")
        #expect(provider.receivedRequest?.images.first?.data == Data([7, 8, 9]))
        #expect(provider.requestCount == 3)
        let runs = InitialAnalysisRunMetadata.decode(meal.activeRevision?.providerMetadata)
        #expect(runs.count == 3)
        #expect(runs.map(\.runNumber) == [1, 2, 3])
        #expect(runs.allSatisfy { $0.modelIdentifier == "example/vision-model" })
        #expect(runs.allSatisfy { $0.energyKilocalories == 640 })

        meal.activeRevision?.portionMultiplier = 1.5
        #expect(meal.activeRevision?.normalizedPortionMultiplier == 1.5)
        #expect(InitialAnalysisRunMetadata.decode(meal.activeRevision?.providerMetadata) == runs)
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
        #expect(meal.analysisRevisions.count == 1)
        #expect(meal.analysisRevisions.first?.status == .failed)
        #expect(meal.analysisRevisions.first?.failureMessage == "OpenRouter ist momentan nicht verfügbar.")
        let calls = InitialAnalysisRunMetadata.decodeCalls(meal.analysisRevisions.first?.providerMetadata)
        #expect(calls.count == 9)
        #expect(calls.allSatisfy { $0.status == .failed })
        #expect(calls.map(\.attemptNumber) == [1, 1, 1, 2, 2, 2, 3, 3, 3])
        #expect(try context.fetch(FetchDescriptor<Meal>()).count == 1)
    }

    @Test("A failed initial request retries only its missing result")
    func retriesOnlyFailedInitialRequest() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let meal = Meal()
        context.insert(meal)
        try context.save()
        let valid = NutritionAnalysisValidatorTests.validResult()
        let provider = SequencedAnalysisProviderStub(outcomes: [
            .success(valid),
            .success(valid),
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

        #expect(provider.requestCount == 4)
        #expect(waiter.waitCount == 1)
        #expect(meal.analysisState == .confirmed)
        #expect(InitialAnalysisRunMetadata.decode(meal.activeRevision?.providerMetadata).count == 3)
        let calls = InitialAnalysisRunMetadata.decodeCalls(meal.activeRevision?.providerMetadata)
        #expect(calls.count == 4)
        #expect(calls.map(\.status) == [.succeeded, .succeeded, .failed, .succeeded])
        #expect(calls.map(\.sampleNumber) == [1, 2, 3, 3])
        #expect(calls.map(\.attemptNumber) == [1, 1, 1, 2])
    }

    @Test("An invalid initial result retries only its missing result")
    func retriesOnlyInvalidInitialResult() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let meal = Meal()
        context.insert(meal)
        try context.save()
        let valid = NutritionAnalysisValidatorTests.validResult()
        let provider = SequencedAnalysisProviderStub(results: [
            valid,
            invalidResult(),
            valid,
            valid,
        ])
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:])
        )

        await coordinator.analyze(meal)

        #expect(provider.requestCount == 4)
        #expect(meal.analysisState == .confirmed)
        #expect(InitialAnalysisRunMetadata.decode(meal.activeRevision?.providerMetadata).count == 3)
    }

    @Test("A timed out initial request retries only its missing result")
    func retriesOnlyTimedOutInitialRequest() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let meal = Meal()
        context.insert(meal)
        try context.save()
        let valid = NutritionAnalysisValidatorTests.validResult()
        let provider = SequencedAnalysisProviderStub(outcomes: [
            .success(valid),
            .failure(OpenRouterClientError.timedOut),
            .success(valid),
            .success(valid),
        ])
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:])
        )

        await coordinator.analyze(meal)

        #expect(provider.requestCount == 4)
        #expect(meal.analysisState == .confirmed)
    }

    @Test("Unreadable responses are retried up to three times per initial request")
    func retriesMalformedInitialResponses() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let meal = Meal()
        context.insert(meal)
        try context.save()
        let valid = NutritionAnalysisValidatorTests.validResult()
        let provider = SequencedAnalysisProviderStub(outcomes: [
            .success(valid), .failure(NutritionAnalysisError.malformedResponse), .success(valid),
            .failure(NutritionAnalysisError.malformedResponse),
            .success(valid),
        ])
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:])
        )

        await coordinator.analyze(meal)

        #expect(provider.requestCount == 5)
        #expect(meal.analysisState == .confirmed)
    }

    @Test("Invalid analysis values restart the complete initial analysis")
    func retriesInvalidResults() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let meal = Meal()
        context.insert(meal)
        try context.save()
        let invalid = invalidResult()
        let valid = NutritionAnalysisValidatorTests.validResult()
        let provider = SequencedAnalysisProviderStub(results: [
            invalid, invalid, invalid,
            valid, valid, valid,
        ])
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:])
        )

        await coordinator.analyze(meal)

        #expect(provider.requestCount == 6)
        #expect(meal.analysisState == .confirmed)
        #expect(meal.analysisRevisions.count == 1)
    }

    @Test("Invalid analysis values fail after three complete attempts")
    func limitsInvalidResultRetries() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let meal = Meal()
        context.insert(meal)
        try context.save()
        let provider = SequencedAnalysisProviderStub(
            results: Array(repeating: invalidResult(), count: 9)
        )
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:])
        )

        await coordinator.analyze(meal)

        #expect(provider.requestCount == 9)
        #expect(meal.analysisState == .failed)
        #expect(meal.analysisRevisions.count == 1)
        #expect(meal.analysisRevisions.first?.failureMessage == "Die Ernährungsanalyse enthielt ungültige Werte.")
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
            .failure(OpenRouterClientError.transportFailure),
            .failure(OpenRouterClientError.transportFailure),
            .success(valid), .success(valid), .success(valid),
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
        #expect(provider.requestCount == 6)
        #expect(meal.analysisState == .confirmed)
    }

    @Test("Offline analyses fail after three complete attempts")
    func limitsOfflineRetries() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let meal = Meal()
        context.insert(meal)
        try context.save()
        let provider = SequencedAnalysisProviderStub(outcomes: Array(
            repeating: .failure(OpenRouterClientError.transportFailure),
            count: 9
        ))
        let waiter = NetworkAvailabilityWaiterStub()
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:]),
            networkAvailabilityWaiter: waiter
        )

        await coordinator.analyze(meal)

        #expect(waiter.waitCount == 2)
        #expect(provider.requestCount == 9)
        #expect(meal.analysisState == .failed)
        #expect(meal.analysisRevisions.first?.failureMessage?.contains("Internetverbindung") == true)
    }

    @Test("Interrupted analyses become retryable after app launch")
    func recoversInterruptedAnalysis() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let meal = Meal(analysisState: .analyzing)
        context.insert(meal)
        try context.save()

        try MealAnalysisCoordinator.recoverInterruptedAnalyses(in: context)

        #expect(meal.analysisState == .failed)
        #expect(meal.analysisRevisions.count == 1)
        #expect(meal.analysisRevisions.first?.failureMessage?.contains("unterbrochen") == true)
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
        #expect(provider.requestCount == 3)
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
        #expect(provider.receivedRequest?.previousAnalysis?.nutrients.count == 8)
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
            firstFollowUp,
            firstFollowUp,
            finalFollowUp,
            finalFollowUp,
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

        #expect(provider.requestCount == 6)
        #expect(meal.analysisState == .awaitingConfirmation)
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

        #expect(provider.requestCount == 3)
        #expect(meal.analysisState == .awaitingConfirmation)
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

        #expect(provider.requestCount == 6)
        #expect(meal.analysisState == .awaitingConfirmation)
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
            unexplained,
            unexplained,
            NutritionAnalysisValidatorTests.validResult(),
        ])
        let coordinator = MealAnalysisCoordinator(
            context: context,
            provider: provider,
            imageStorage: AnalysisImageStorage(dataByKey: [:])
        )

        await coordinator.answerClarification("Zwei Esslöffel", for: meal)

        #expect(provider.requestCount == 6)
        #expect(meal.analysisState == .awaitingConfirmation)
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

        #expect(meal.analysisState == .confirmed)
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
        return NutritionAnalysisResult(
            mealName: valid.mealName,
            estimatedTotalWeightGrams: valid.estimatedTotalWeightGrams,
            confidence: valid.confidence,
            uncertaintySummary: uncertaintySummary,
            clarificationQuestion: clarificationQuestion,
            nutrients: valid.nutrients.map { nutrient in
                guard nutrient.identifier == .energy else { return nutrient }
                return AnalyzedNutrient(
                    identifier: nutrient.identifier,
                    value: energy,
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
private final class NetworkAvailabilityWaiterStub: NetworkAvailabilityWaiting {
    private(set) var waitCount = 0

    func waitUntilAvailable() async throws {
        waitCount += 1
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

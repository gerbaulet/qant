import Foundation
import OSLog
import SwiftData

@MainActor
final class MealAnalysisCoordinator {
    static let maximumClarificationCount = 2
    static let maximumAutomaticAttemptCount = 3

    static func recoverInterruptedAnalyses(in context: ModelContext, now: Date = .now) throws {
        let meals = try context.fetch(FetchDescriptor<Meal>())
        var recoveredAny = false
        for meal in meals where meal.analysisState == .analyzing {
            let previousRevision = meal.activeRevision
            meal.analysisRevisions.append(failureRevision(
                requestedAt: meal.modifiedAt,
                createdAt: now,
                trigger: previousRevision == nil ? .initial : .retry,
                message: "Die Analyse wurde beim Beenden der App unterbrochen. Du kannst sie erneut versuchen.",
                previousRevision: previousRevision
            ))
            meal.analysisState = .failed
            meal.modifiedAt = now
            recoveredAny = true
        }
        if recoveredAny { try context.save() }
    }

    private let context: ModelContext
    private let provider: any NutritionAnalysisProviding
    private let imageStorage: any ImageStorageProviding
    private let networkAvailabilityWaiter: any NetworkAvailabilityWaiting
    private let now: () -> Date

    init(
        context: ModelContext,
        provider: any NutritionAnalysisProviding,
        imageStorage: any ImageStorageProviding,
        networkAvailabilityWaiter: any NetworkAvailabilityWaiting = SystemNetworkAvailabilityWaiter(),
        now: @escaping () -> Date = Date.init
    ) {
        self.context = context
        self.provider = provider
        self.imageStorage = imageStorage
        self.networkAvailabilityWaiter = networkAvailabilityWaiter
        self.now = now
    }

    convenience init(
        context: ModelContext,
        now: @escaping () -> Date = Date.init
    ) {
        self.init(
            context: context,
            provider: OpenRouterNutritionAnalysisService(),
            imageStorage: FileImageStorage(),
            now: now
        )
    }

    func analyze(_ meal: Meal) async {
        guard meal.analysisState == .pending || meal.analysisState == .failed else { return }
        if meal.analysisState == .failed,
           let correction = latestFailedCorrection(for: meal) {
            await performAnalysis(meal, trigger: .correction, userCorrection: correction)
        } else {
            await performAnalysis(meal, trigger: meal.analysisState == .failed ? .retry : .initial)
        }
    }

    func answerClarification(_ answer: String, for meal: Meal) async {
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            meal.analysisState == .needsClarification,
            meal.activeRevision != nil,
            meal.clarificationCount < Self.maximumClarificationCount,
            !trimmedAnswer.isEmpty
        else { return }
        await performAnalysis(
            meal,
            trigger: .clarification,
            clarificationAnswer: trimmedAnswer
        )
    }

    func useBestEstimate(for meal: Meal) async {
        guard meal.analysisState == .needsClarification, meal.activeRevision != nil else { return }
        await performAnalysis(meal, trigger: .bestEstimate)
    }

    func correct(_ correction: String, for meal: Meal) async {
        let trimmedCorrection = correction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            meal.analysisState == .awaitingConfirmation || meal.analysisState == .confirmed,
            meal.activeRevision != nil,
            !trimmedCorrection.isEmpty
        else { return }
        await performAnalysis(
            meal,
            trigger: .correction,
            userCorrection: trimmedCorrection
        )
    }

    func confirm(_ meal: Meal) throws {
        guard
            meal.analysisState == .awaitingConfirmation,
            let revision = meal.activeRevision,
            revision.status == .awaitingConfirmation
        else {
            throw NutritionAnalysisError.invalidState
        }

        revision.status = .confirmed
        meal.analysisState = .confirmed
        meal.modifiedAt = now()
        try context.save()
    }

    private func performAnalysis(
        _ meal: Meal,
        trigger: AnalysisTrigger,
        clarificationAnswer: String? = nil,
        userCorrection: String? = nil
    ) async {
        let previousMealState = meal.analysisState
        let preservedPortionMultiplier = meal.activeRevision?.normalizedPortionMultiplier ?? 1
        let previousAnalysis = meal.activeRevision.map(makeBaselineAnalysisResult)
        let nextClarificationCount = trigger == .clarification
            ? meal.clarificationCount + 1
            : meal.clarificationCount
        let allowsClarification = trigger != .bestEstimate &&
            trigger != .correction &&
            nextClarificationCount < Self.maximumClarificationCount

        let requestDate = now()
        AppLogger.nutritionAnalysis.info("Starting nutrition analysis")
        meal.analysisState = .analyzing
        meal.modifiedAt = requestDate
        do {
            try context.save()

            let images = try await meal.images
                .sorted { $0.sortIndex < $1.sortIndex }
                .asyncMap { image in
                    NutritionAnalysisImage(
                        data: try await imageStorage.data(forStorageKey: image.imageStorageKey)
                    )
                }
            let request = NutritionAnalysisRequest(
                images: images,
                userComment: meal.userComment,
                previousAnalysis: previousAnalysis,
                clarificationHistory: clarificationHistory(for: meal),
                clarificationAnswer: clarificationAnswer,
                userCorrection: userCorrection,
                requestsBestEstimate: trigger == .bestEstimate,
                allowsClarification: allowsClarification
            )
            let (result, initialResults) = try await requestValidAnalysis(
                request,
                trigger: trigger
            )
            persist(
                result,
                requestedAt: requestDate,
                trigger: trigger,
                clarificationAnswer: clarificationAnswer,
                userCorrection: userCorrection,
                initialResults: initialResults,
                portionMultiplier: preservedPortionMultiplier,
                for: meal
            )
            meal.clarificationCount = nextClarificationCount
            try context.save()
            AppLogger.nutritionAnalysis.info("Nutrition analysis completed")
        } catch is CancellationError {
            meal.analysisState = previousMealState
            meal.modifiedAt = now()
            try? context.save()
            AppLogger.nutritionAnalysis.info("Nutrition analysis cancelled")
        } catch {
            persistFailure(
                requestedAt: requestDate,
                trigger: trigger,
                userCorrection: userCorrection,
                error: error,
                for: meal
            )
            meal.analysisState = .failed
            meal.modifiedAt = now()
            try? context.save()
            AppLogger.nutritionAnalysis.error("Nutrition analysis failed")
        }
    }

    private func clarificationHistory(for meal: Meal) -> [NutritionClarificationExchange] {
        let revisions = meal.analysisRevisions.sorted { $0.createdAt < $1.createdAt }
        return revisions.enumerated().compactMap { index, revision in
            guard
                revision.trigger == .clarification,
                let answer = revision.clarificationAnswer?.trimmingCharacters(in: .whitespacesAndNewlines),
                !answer.isEmpty,
                index > 0,
                let question = revisions[index - 1].clarificationQuestion?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !question.isEmpty
            else { return nil }
            return NutritionClarificationExchange(question: question, answer: answer)
        }
    }

    private func requestValidAnalysis(
        _ request: NutritionAnalysisRequest,
        trigger: AnalysisTrigger
    ) async throws -> (NutritionAnalysisResult, [NutritionAnalysisResult]) {
        if trigger == .initial {
            let sampleResults = try await requestInitialSample(request)
            let result = try NutritionAnalysisConsensus.combine(
                sampleResults,
                allowsClarification: request.allowsClarification
            )
            try NutritionAnalysisValidator.validate(result)
            return (result, sampleResults)
        }
        if trigger == .clarification {
            for attempt in 1...Self.maximumAutomaticAttemptCount {
                do {
                    let sampleResults = try await requestInitialSample(request)
                    let result = try NutritionAnalysisConsensus.combine(
                        sampleResults,
                        allowsClarification: request.allowsClarification
                    )
                    try NutritionAnalysisValidator.validate(result)
                    try NutritionAnalysisConsistencyValidator.validate(result)
                    try NutritionAnalysisDriftValidator.validate(
                        previous: request.previousAnalysis,
                        revised: result
                    )
                    return (result, [])
                } catch let error as NutritionAnalysisError {
                    guard case .invalidResult = error,
                          attempt < Self.maximumAutomaticAttemptCount else {
                        throw error
                    }
                    AppLogger.nutritionAnalysis.info("Retrying clarification after inconsistent consensus")
                }
            }
            throw NutritionAnalysisError.invalidResult("automatic retry limit reached")
        }

        for attempt in 1...Self.maximumAutomaticAttemptCount {
            do {
                let result = try await provider.analyze(request)
                try NutritionAnalysisValidator.validate(result)
                return (result, [])
            } catch {
                guard Self.isRetryable(error),
                      attempt < Self.maximumAutomaticAttemptCount else { throw error }
                if Self.isTransportFailure(error) {
                    AppLogger.nutritionAnalysis.info("Waiting for network before retrying analysis")
                    try await networkAvailabilityWaiter.waitUntilAvailable()
                } else {
                    AppLogger.nutritionAnalysis.info("Retrying failed analysis request")
                }
            }
        }
        throw NutritionAnalysisError.invalidResult("automatic retry limit reached")
    }

    private func requestInitialSample(
        _ request: NutritionAnalysisRequest
    ) async throws -> [NutritionAnalysisResult] {
        var results = Array<NutritionAnalysisResult?>(
            repeating: nil,
            count: NutritionAnalysisConsensus.initialSampleCount
        )

        for attempt in 1...Self.maximumAutomaticAttemptCount {
            let missingIndexes = results.indices.filter { results[$0] == nil }
            let outcomes = await requestOutcomes(for: missingIndexes, request: request)
            var retryError: Error?
            var encounteredTransportFailure = false

            for (index, outcome) in zip(missingIndexes, outcomes) {
                switch outcome {
                case let .success(result):
                    do {
                        try NutritionAnalysisValidator.validate(result)
                        results[index] = result
                    } catch {
                        retryError = error
                    }
                case let .failure(error):
                    guard Self.isRetryable(error) else { throw error }
                    retryError = error
                    encounteredTransportFailure = encounteredTransportFailure || Self.isTransportFailure(error)
                }
            }

            if results.allSatisfy({ $0 != nil }) {
                return results.compactMap { $0 }
            }
            guard attempt < Self.maximumAutomaticAttemptCount else {
                throw retryError ?? NutritionAnalysisError.invalidResult("automatic retry limit reached")
            }
            if encounteredTransportFailure {
                AppLogger.nutritionAnalysis.info("Waiting for network before retrying missing analyses")
                try await networkAvailabilityWaiter.waitUntilAvailable()
            } else {
                AppLogger.nutritionAnalysis.info("Retrying missing analysis after invalid result")
            }
        }

        throw NutritionAnalysisError.invalidResult("automatic retry limit reached")
    }

    private func requestOutcomes(
        for indexes: [Int],
        request: NutritionAnalysisRequest
    ) async -> [Result<NutritionAnalysisResult, Error>] {
        switch indexes.count {
        case 1:
            return [await requestOutcome(request)]
        case 2:
            async let first = requestOutcome(request)
            async let second = requestOutcome(request)
            return await [first, second]
        case 3:
            async let first = requestOutcome(request)
            async let second = requestOutcome(request)
            async let third = requestOutcome(request)
            return await [first, second, third]
        default:
            return []
        }
    }

    private func requestOutcome(
        _ request: NutritionAnalysisRequest
    ) async -> Result<NutritionAnalysisResult, Error> {
        do {
            return .success(try await provider.analyze(request))
        } catch {
            return .failure(error)
        }
    }

    private static func isTransportFailure(_ error: Error) -> Bool {
        (error as? OpenRouterClientError) == .transportFailure
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if let analysisError = error as? NutritionAnalysisError {
            switch analysisError {
            case .malformedResponse, .invalidResult:
                return true
            case .missingConfiguration, .invalidState:
                return false
            }
        }
        guard let clientError = error as? OpenRouterClientError else { return false }
        switch clientError {
        case .transportFailure, .timedOut, .serverError, .rateLimited, .invalidResponse:
            return true
        case let .apiError(statusCode, _):
            return statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
        case .invalidAPIKey, .accessForbidden, .invalidModelIdentifier, .modelUnavailable, .modelNotFound,
                .invalidRequest, .insufficientCredits:
            return false
        }
    }

    private func latestFailedCorrection(for meal: Meal) -> String? {
        meal.analysisRevisions
            .filter { $0.status == .failed && $0.trigger == .correction }
            .sorted { $0.createdAt > $1.createdAt }
            .first?
            .userCorrection
    }

    private func persistFailure(
        requestedAt requestDate: Date,
        trigger: AnalysisTrigger,
        userCorrection: String?,
        error: Error,
        for meal: Meal
    ) {
        meal.analysisRevisions.append(Self.failureRevision(
            requestedAt: requestDate,
            createdAt: now(),
            trigger: trigger,
            userCorrection: userCorrection,
            message: error.localizedDescription,
            previousRevision: meal.activeRevision
        ))
    }

    private static func failureRevision(
        requestedAt requestDate: Date,
        createdAt: Date,
        trigger: AnalysisTrigger,
        userCorrection: String? = nil,
        message: String,
        previousRevision: MealAnalysisRevision?
    ) -> MealAnalysisRevision {
        MealAnalysisRevision(
            createdAt: createdAt,
            requestDate: requestDate,
            modelIdentifier: previousRevision?.modelIdentifier ?? "Nicht verfügbar",
            providerIdentifier: previousRevision?.providerIdentifier,
            promptVersion: NutritionAnalysisPrompt.currentVersion,
            trigger: trigger,
            status: .failed,
            mealName: previousRevision?.mealName ?? "Analyse fehlgeschlagen",
            estimatedTotalWeightGrams: previousRevision?.estimatedTotalWeightGrams,
            confidence: previousRevision?.confidence ?? .low,
            uncertaintySummary: previousRevision?.uncertaintySummary,
            userCorrection: userCorrection,
            failureMessage: message
        )
    }

    private func persist(
        _ result: NutritionAnalysisResult,
        requestedAt requestDate: Date,
        trigger: AnalysisTrigger,
        clarificationAnswer: String?,
        userCorrection: String?,
        initialResults: [NutritionAnalysisResult],
        portionMultiplier: Double,
        for meal: Meal
    ) {
        let asksClarification = result.clarificationQuestion?.isEmpty == false
        let hasClarificationHistory = meal.clarificationCount > 0 || meal.analysisRevisions.contains {
            $0.clarificationQuestion?.isEmpty == false
        }
        let status: AnalysisState
        if asksClarification {
            status = .needsClarification
        } else if hasClarificationHistory {
            status = .awaitingConfirmation
        } else {
            status = .confirmed
        }
        let revision = MealAnalysisRevision(
            createdAt: now(),
            requestDate: requestDate,
            modelIdentifier: result.modelIdentifier,
            providerIdentifier: result.providerIdentifier,
            providerMetadata: InitialAnalysisRunMetadata.encode(initialResults),
            promptVersion: NutritionAnalysisPrompt.currentVersion,
            trigger: trigger,
            status: status,
            mealName: result.mealName.trimmingCharacters(in: .whitespacesAndNewlines),
            estimatedTotalWeightGrams: result.estimatedTotalWeightGrams,
            confidence: result.confidence,
            uncertaintySummary: result.uncertaintySummary,
            clarificationQuestion: result.clarificationQuestion,
            clarificationAnswer: clarificationAnswer,
            userCorrection: userCorrection,
            components: result.components.enumerated().map { index, component in
                FoodComponent(
                    sortIndex: index,
                    name: component.name,
                    estimatedWeightGrams: component.estimatedWeightGrams,
                    nutrients: component.nutrients.map(makeNutrient)
                )
            },
            nutrients: result.nutrients.map(makeNutrient)
        )
        if trigger != .initial {
            revision.portionMultiplier = portionMultiplier
        }

        meal.analysisRevisions.append(revision)
        meal.activeRevisionID = revision.id
        meal.analysisState = status
        meal.modifiedAt = now()
    }

    private func makeBaselineAnalysisResult(_ revision: MealAnalysisRevision) -> NutritionAnalysisResult {
        NutritionAnalysisResult(
            mealName: revision.mealName,
            estimatedTotalWeightGrams: revision.estimatedTotalWeightGrams,
            confidence: revision.confidence,
            uncertaintySummary: revision.uncertaintySummary,
            clarificationQuestion: revision.clarificationQuestion,
            nutrients: revision.nutrients.compactMap {
                makeAnalyzedNutrient($0)
            },
            components: revision.components
                .sorted { $0.sortIndex < $1.sortIndex }
                .map { component in
                    AnalyzedFoodComponent(
                        name: component.name,
                        estimatedWeightGrams: nil,
                        nutrients: []
                    )
                },
            modelIdentifier: revision.modelIdentifier,
            providerIdentifier: revision.providerIdentifier
        )
    }

    private func makeAnalyzedNutrient(
        _ nutrient: NutrientValue,
        multiplier: Double = 1
    ) -> AnalyzedNutrient? {
        guard let identifier = nutrient.knownIdentifier, let unit = nutrient.knownUnit else {
            return nil
        }
        return AnalyzedNutrient(
            identifier: identifier,
            value: nutrient.value * multiplier,
            unit: unit,
            confidence: nutrient.confidence,
            provenance: nutrient.provenance
        )
    }

    private func makeNutrient(_ nutrient: AnalyzedNutrient) -> NutrientValue {
        NutrientValue(
            identifier: nutrient.identifier,
            value: nutrient.value,
            unit: nutrient.unit,
            confidence: nutrient.confidence,
            provenance: nutrient.provenance
        )
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        values.reserveCapacity(underestimatedCount)
        for element in self {
            let value = try await transform(element)
            values.append(value)
        }
        return values
    }
}

import Foundation
import OSLog
import SwiftData

@MainActor
final class MealAnalysisCoordinator {
    static let maximumClarificationCount = 2

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
    private let now: () -> Date

    init(
        context: ModelContext,
        provider: any NutritionAnalysisProviding,
        imageStorage: any ImageStorageProviding,
        now: @escaping () -> Date = Date.init
    ) {
        self.context = context
        self.provider = provider
        self.imageStorage = imageStorage
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
        let previousAnalysis = meal.activeRevision.map(makeAnalysisResult)
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
                clarificationAnswer: clarificationAnswer,
                userCorrection: userCorrection,
                requestsBestEstimate: trigger == .bestEstimate,
                allowsClarification: allowsClarification
            )
            let result: NutritionAnalysisResult
            let initialResults: [NutritionAnalysisResult]
            if trigger == .initial {
                async let firstAnalysis = provider.analyze(request)
                async let secondAnalysis = provider.analyze(request)
                async let thirdAnalysis = provider.analyze(request)
                initialResults = try await [firstAnalysis, secondAnalysis, thirdAnalysis]
                for candidate in initialResults {
                    try NutritionAnalysisValidator.validate(candidate)
                }
                result = try NutritionAnalysisConsensus.combine(initialResults)
            } else {
                initialResults = []
                result = try await provider.analyze(request)
            }
            try NutritionAnalysisValidator.validate(result)
            persist(
                result,
                requestedAt: requestDate,
                trigger: trigger,
                clarificationAnswer: clarificationAnswer,
                userCorrection: userCorrection,
                initialResults: initialResults,
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

        meal.analysisRevisions.append(revision)
        meal.activeRevisionID = revision.id
        meal.analysisState = status
        meal.modifiedAt = now()
    }

    private func makeAnalysisResult(_ revision: MealAnalysisRevision) -> NutritionAnalysisResult {
        NutritionAnalysisResult(
            mealName: revision.mealName,
            estimatedTotalWeightGrams: revision.estimatedTotalWeightGrams.map(revision.scaled),
            confidence: revision.confidence,
            uncertaintySummary: revision.uncertaintySummary,
            clarificationQuestion: revision.clarificationQuestion,
            nutrients: revision.nutrients.compactMap {
                makeAnalyzedNutrient($0, multiplier: revision.normalizedPortionMultiplier)
            },
            components: revision.components
                .sorted { $0.sortIndex < $1.sortIndex }
                .map { component in
                    AnalyzedFoodComponent(
                        name: component.name,
                        estimatedWeightGrams: component.estimatedWeightGrams.map(revision.scaled),
                        nutrients: component.nutrients.compactMap {
                            makeAnalyzedNutrient($0, multiplier: revision.normalizedPortionMultiplier)
                        }
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

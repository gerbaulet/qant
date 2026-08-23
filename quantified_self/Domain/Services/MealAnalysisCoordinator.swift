import Foundation
import OSLog
import SwiftData

@MainActor
final class MealAnalysisCoordinator {
    static let maximumClarificationCount = 2

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
            let result = try await provider.analyze(NutritionAnalysisRequest(
                images: images,
                userComment: meal.userComment,
                previousAnalysis: previousAnalysis,
                clarificationAnswer: clarificationAnswer,
                userCorrection: userCorrection,
                requestsBestEstimate: trigger == .bestEstimate,
                allowsClarification: allowsClarification
            ))
            try NutritionAnalysisValidator.validate(result)
            persist(
                result,
                requestedAt: requestDate,
                trigger: trigger,
                clarificationAnswer: clarificationAnswer,
                userCorrection: userCorrection,
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
            if trigger == .correction, let userCorrection {
                persistCorrectionFailure(
                    userCorrection,
                    requestedAt: requestDate,
                    error: error,
                    for: meal
                )
            }
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

    private func persistCorrectionFailure(
        _ correction: String,
        requestedAt requestDate: Date,
        error: Error,
        for meal: Meal
    ) {
        guard let previousRevision = meal.activeRevision else { return }
        meal.analysisRevisions.append(MealAnalysisRevision(
            createdAt: now(),
            requestDate: requestDate,
            modelIdentifier: previousRevision.modelIdentifier,
            providerIdentifier: previousRevision.providerIdentifier,
            promptVersion: NutritionAnalysisPrompt.currentVersion,
            trigger: .correction,
            status: .failed,
            mealName: previousRevision.mealName,
            estimatedTotalWeightGrams: previousRevision.estimatedTotalWeightGrams,
            confidence: previousRevision.confidence,
            uncertaintySummary: previousRevision.uncertaintySummary,
            userCorrection: correction,
            failureMessage: error.localizedDescription
        ))
    }

    private func persist(
        _ result: NutritionAnalysisResult,
        requestedAt requestDate: Date,
        trigger: AnalysisTrigger,
        clarificationAnswer: String?,
        userCorrection: String?,
        for meal: Meal
    ) {
        let status: AnalysisState = result.clarificationQuestion?.isEmpty == false
            ? .needsClarification
            : .awaitingConfirmation
        let revision = MealAnalysisRevision(
            createdAt: now(),
            requestDate: requestDate,
            modelIdentifier: result.modelIdentifier,
            providerIdentifier: result.providerIdentifier,
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
            estimatedTotalWeightGrams: revision.estimatedTotalWeightGrams,
            confidence: revision.confidence,
            uncertaintySummary: revision.uncertaintySummary,
            clarificationQuestion: revision.clarificationQuestion,
            nutrients: revision.nutrients.compactMap(makeAnalyzedNutrient),
            components: revision.components
                .sorted { $0.sortIndex < $1.sortIndex }
                .map { component in
                    AnalyzedFoodComponent(
                        name: component.name,
                        estimatedWeightGrams: component.estimatedWeightGrams,
                        nutrients: component.nutrients.compactMap(makeAnalyzedNutrient)
                    )
                },
            modelIdentifier: revision.modelIdentifier,
            providerIdentifier: revision.providerIdentifier
        )
    }

    private func makeAnalyzedNutrient(_ nutrient: NutrientValue) -> AnalyzedNutrient? {
        guard let identifier = nutrient.knownIdentifier, let unit = nutrient.knownUnit else {
            return nil
        }
        return AnalyzedNutrient(
            identifier: identifier,
            value: nutrient.value,
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

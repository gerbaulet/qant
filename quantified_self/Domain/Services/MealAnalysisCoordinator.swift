import Foundation
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
        provider: any NutritionAnalysisProviding = OpenRouterNutritionAnalysisService(),
        imageStorage: any ImageStorageProviding = FileImageStorage(),
        now: @escaping () -> Date = Date.init
    ) {
        self.context = context
        self.provider = provider
        self.imageStorage = imageStorage
        self.now = now
    }

    func analyze(_ meal: Meal) async {
        guard meal.analysisState == .pending || meal.analysisState == .failed else { return }
        await performAnalysis(meal, trigger: meal.analysisState == .failed ? .retry : .initial)
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
        clarificationAnswer: String? = nil
    ) async {
        let previousMealState = meal.analysisState
        let previousAnalysis = meal.activeRevision.map(makeAnalysisResult)
        let nextClarificationCount = trigger == .clarification
            ? meal.clarificationCount + 1
            : meal.clarificationCount
        let allowsClarification = trigger != .bestEstimate &&
            nextClarificationCount < Self.maximumClarificationCount

        let requestDate = now()
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
                requestsBestEstimate: trigger == .bestEstimate,
                allowsClarification: allowsClarification
            ))
            try NutritionAnalysisValidator.validate(result)
            persist(
                result,
                requestedAt: requestDate,
                trigger: trigger,
                clarificationAnswer: clarificationAnswer,
                for: meal
            )
            meal.clarificationCount = nextClarificationCount
            try context.save()
        } catch is CancellationError {
            meal.analysisState = previousMealState
            meal.modifiedAt = now()
            try? context.save()
        } catch {
            meal.analysisState = .failed
            meal.modifiedAt = now()
            try? context.save()
        }
    }

    private func persist(
        _ result: NutritionAnalysisResult,
        requestedAt requestDate: Date,
        trigger: AnalysisTrigger,
        clarificationAnswer: String?,
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

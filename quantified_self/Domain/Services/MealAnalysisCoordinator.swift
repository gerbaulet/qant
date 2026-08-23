import Foundation
import SwiftData

@MainActor
final class MealAnalysisCoordinator {
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
                userComment: meal.userComment
            ))
            try NutritionAnalysisValidator.validate(result)
            persist(result, requestedAt: requestDate, for: meal)
            try context.save()
        } catch is CancellationError {
            meal.analysisState = .pending
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
            trigger: .initial,
            status: status,
            mealName: result.mealName.trimmingCharacters(in: .whitespacesAndNewlines),
            estimatedTotalWeightGrams: result.estimatedTotalWeightGrams,
            confidence: result.confidence,
            uncertaintySummary: result.uncertaintySummary,
            clarificationQuestion: result.clarificationQuestion,
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

import Foundation
import OSLog
import SwiftData

struct MealDraft: Sendable {
    let timestamp: Date
    let comment: String
    let category: MealCategory
    let images: [StoredMealImage]
    let analysisState: AnalysisState

    init(
        timestamp: Date,
        comment: String,
        category: MealCategory,
        images: [StoredMealImage] = [],
        analysisState: AnalysisState = .pending
    ) {
        self.timestamp = timestamp
        self.comment = comment
        self.category = category
        self.images = images
        self.analysisState = analysisState
    }
}

@MainActor
protocol MealRepository {
    @discardableResult
    func createMeal(from draft: MealDraft, now: Date) throws -> Meal

    func updateTimestamp(_ timestamp: Date, for meal: Meal, now: Date) throws

    func addDescription(_ description: String, to meal: Meal, now: Date) throws

    @discardableResult
    func duplicateMeal(_ meal: Meal, images: [StoredMealImage], now: Date) throws -> Meal

    @discardableResult
    func deleteMeal(_ meal: Meal) throws -> [StoredMealImage]
}

enum MealDuplicationError: Error, LocalizedError {
    case invalidSource

    var errorDescription: String? {
        switch self {
        case .invalidSource:
            "Nur bestätigte Mahlzeiten mit einem gültigen Ergebnis können dupliziert werden."
        }
    }
}

extension Meal {
    var canBeDuplicated: Bool {
        analysisState == .confirmed && activeRevision?.status == .confirmed
    }
}

@MainActor
final class SwiftDataMealRepository: MealRepository {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    @discardableResult
    func createMeal(from draft: MealDraft, now: Date = .now) throws -> Meal {
        let trimmedComment = draft.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let meal = Meal(
            createdAt: now,
            modifiedAt: now,
            timestamp: draft.timestamp,
            userComment: trimmedComment.isEmpty ? nil : trimmedComment,
            category: draft.category,
            mealState: .captured,
            analysisState: draft.analysisState,
            images: draft.images.enumerated().map { index, image in
                MealImage(
                    id: image.id,
                    sortIndex: index,
                    imageStorageKey: image.imageStorageKey,
                    thumbnailStorageKey: image.thumbnailStorageKey,
                    pixelWidth: image.pixelWidth,
                    pixelHeight: image.pixelHeight
                )
            }
        )

        context.insert(meal)
        do {
            try context.save()
            AppLogger.persistence.info("Meal saved locally")
            return meal
        } catch {
            context.delete(meal)
            AppLogger.persistence.error("Local meal save failed")
            throw error
        }
    }

    func addDescription(_ description: String, to meal: Meal, now: Date = .now) throws {
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard meal.analysisState == .awaitingDescription, !trimmedDescription.isEmpty else {
            throw NutritionAnalysisError.invalidState
        }
        let previousComment = meal.userComment
        let previousState = meal.analysisState
        let previousModifiedAt = meal.modifiedAt
        meal.userComment = trimmedDescription
        meal.analysisState = .pending
        meal.modifiedAt = now

        do {
            try context.save()
            AppLogger.persistence.info("Meal description saved locally")
        } catch {
            meal.userComment = previousComment
            meal.analysisState = previousState
            meal.modifiedAt = previousModifiedAt
            AppLogger.persistence.error("Meal description update failed")
            throw error
        }
    }

    func updateTimestamp(_ timestamp: Date, for meal: Meal, now: Date = .now) throws {
        let previousTimestamp = meal.timestamp
        let previousModifiedAt = meal.modifiedAt
        meal.timestamp = timestamp
        meal.modifiedAt = now

        do {
            try context.save()
            AppLogger.persistence.info("Meal timestamp updated locally")
        } catch {
            meal.timestamp = previousTimestamp
            meal.modifiedAt = previousModifiedAt
            AppLogger.persistence.error("Meal timestamp update failed")
            throw error
        }
    }

    @discardableResult
    func duplicateMeal(
        _ meal: Meal,
        images: [StoredMealImage],
        now: Date = .now
    ) throws -> Meal {
        guard meal.canBeDuplicated, let sourceRevision = meal.activeRevision else {
            throw MealDuplicationError.invalidSource
        }

        let sourceComponents = sourceRevision.components.sorted { $0.sortIndex < $1.sortIndex }
        let copiedComponents = sourceComponents.map(copyComponent)
        let copiedComponentBySourceID = Dictionary(
            uniqueKeysWithValues: zip(
                sourceComponents,
                copiedComponents
            ).map { ($0.id, $1) }
        )
        let sourceComponentMultipliers = InitialAnalysisRunMetadata.componentMultipliers(
            from: sourceRevision.providerMetadata
        )
        let copiedComponentMultipliers = sourceComponentMultipliers.reduce(
            into: [String: Double]()
        ) { result, entry in
            guard
                let sourceID = UUID(uuidString: entry.key),
                let copiedComponent = copiedComponentBySourceID[sourceID]
            else { return }
            result[copiedComponent.id.uuidString] = entry.value
        }
        var copiedMetadata = InitialAnalysisRunMetadata.settingPortionMultiplier(
            sourceRevision.normalizedPortionMultiplier,
            in: nil
        )
        copiedMetadata = InitialAnalysisRunMetadata.settingComponentMultipliers(
            copiedComponentMultipliers,
            in: copiedMetadata
        )

        let copiedRevision = MealAnalysisRevision(
            createdAt: now,
            requestDate: now,
            modelIdentifier: sourceRevision.modelIdentifier,
            providerIdentifier: sourceRevision.providerIdentifier,
            providerMetadata: copiedMetadata,
            promptVersion: sourceRevision.promptVersion,
            trigger: .initial,
            status: .confirmed,
            mealName: sourceRevision.mealName,
            estimatedTotalWeightGrams: sourceRevision.estimatedTotalWeightGrams,
            confidence: sourceRevision.confidence,
            uncertaintySummary: sourceRevision.uncertaintySummary,
            components: copiedComponents,
            nutrients: sourceRevision.nutrients.map(copyNutrient)
        )
        let duplicate = Meal(
            createdAt: now,
            modifiedAt: now,
            timestamp: now,
            userComment: meal.userComment,
            category: meal.category,
            mealState: .captured,
            analysisState: .confirmed,
            activeRevisionID: copiedRevision.id,
            images: images.enumerated().map { index, image in
                MealImage(
                    id: image.id,
                    createdAt: now,
                    sortIndex: index,
                    imageStorageKey: image.imageStorageKey,
                    thumbnailStorageKey: image.thumbnailStorageKey,
                    pixelWidth: image.pixelWidth,
                    pixelHeight: image.pixelHeight
                )
            },
            analysisRevisions: [copiedRevision]
        )

        context.insert(duplicate)
        do {
            try context.save()
            AppLogger.persistence.info("Meal duplicated locally")
            return duplicate
        } catch {
            context.delete(duplicate)
            AppLogger.persistence.error("Local meal duplication failed")
            throw error
        }
    }

    @discardableResult
    func deleteMeal(_ meal: Meal) throws -> [StoredMealImage] {
        let storedImages = meal.images.map {
            StoredMealImage(
                id: $0.id,
                imageStorageKey: $0.imageStorageKey,
                thumbnailStorageKey: $0.thumbnailStorageKey,
                pixelWidth: $0.pixelWidth,
                pixelHeight: $0.pixelHeight
            )
        }

        context.delete(meal)
        do {
            try context.save()
            AppLogger.persistence.info("Meal deleted locally")
            return storedImages
        } catch {
            AppLogger.persistence.error("Local meal deletion failed")
            throw error
        }
    }

    private func copyComponent(_ source: FoodComponent) -> FoodComponent {
        FoodComponent(
            sortIndex: source.sortIndex,
            name: source.name,
            estimatedWeightGrams: source.estimatedWeightGrams,
            nutrients: source.nutrients.map(copyNutrient)
        )
    }

    private func copyNutrient(_ source: NutrientValue) -> NutrientValue {
        NutrientValue(
            rawIdentifier: source.identifierRawValue,
            value: source.value,
            rawUnit: source.unitRawValue,
            confidence: source.confidence,
            provenance: source.provenance
        )
    }
}

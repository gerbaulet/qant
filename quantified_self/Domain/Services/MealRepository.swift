import Foundation
import SwiftData

struct MealDraft: Sendable {
    let timestamp: Date
    let comment: String
    let category: MealCategory
    let images: [StoredMealImage]

    init(
        timestamp: Date,
        comment: String,
        category: MealCategory,
        images: [StoredMealImage] = []
    ) {
        self.timestamp = timestamp
        self.comment = comment
        self.category = category
        self.images = images
    }
}

@MainActor
protocol MealRepository {
    @discardableResult
    func createMeal(from draft: MealDraft, now: Date) throws -> Meal
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
            analysisState: .pending,
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
            return meal
        } catch {
            context.delete(meal)
            throw error
        }
    }
}

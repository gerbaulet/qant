import Foundation
import SwiftData

@MainActor
final class MealDuplicationCoordinator {
    private let repository: any MealRepository
    private let imageStorage: any ImageStorageProviding

    init(context: ModelContext) {
        self.repository = SwiftDataMealRepository(context: context)
        self.imageStorage = FileImageStorage()
    }

    init(context: ModelContext, imageStorage: any ImageStorageProviding) {
        self.repository = SwiftDataMealRepository(context: context)
        self.imageStorage = imageStorage
    }

    init(
        repository: any MealRepository,
        imageStorage: any ImageStorageProviding
    ) {
        self.repository = repository
        self.imageStorage = imageStorage
    }

    func duplicate(_ meal: Meal, now: Date = .now) async throws -> Meal {
        guard meal.canBeDuplicated else {
            throw MealDuplicationError.invalidSource
        }

        var copiedImages: [StoredMealImage] = []
        do {
            for image in meal.images.sorted(by: { $0.sortIndex < $1.sortIndex }) {
                let storedImage = StoredMealImage(
                    id: image.id,
                    imageStorageKey: image.imageStorageKey,
                    thumbnailStorageKey: image.thumbnailStorageKey,
                    pixelWidth: image.pixelWidth,
                    pixelHeight: image.pixelHeight
                )
                copiedImages.append(try await imageStorage.duplicateImage(storedImage))
            }
            return try repository.duplicateMeal(meal, images: copiedImages, now: now)
        } catch {
            for image in copiedImages {
                await imageStorage.deleteImage(image)
            }
            throw error
        }
    }
}

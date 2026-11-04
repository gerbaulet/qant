import CoreGraphics
import Testing
@testable import Quant

@MainActor
struct MealPhotoZoomTests {
    @Test("Double tap zooms in and resets an enlarged photo")
    func doubleTapScale() {
        #expect(MealPhotoZoomPolicy.doubleTapScale(currentScale: 1, maximumScale: 5) == 3)
        #expect(MealPhotoZoomPolicy.doubleTapScale(currentScale: 3, maximumScale: 5) == 1)
    }

    @Test("Double tap respects a lower maximum scale")
    func lowerMaximumScale() {
        #expect(MealPhotoZoomPolicy.doubleTapScale(currentScale: 1, maximumScale: 2) == 2)
    }
}

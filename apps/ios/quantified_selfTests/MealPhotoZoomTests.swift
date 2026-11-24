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

    @Test("A deliberate downward drag dismisses an enabled view")
    func downwardDismiss() {
        #expect(DownwardDismissGesturePolicy.shouldDismiss(
            translation: CGSize(width: 10, height: 120),
            predictedEndTranslation: CGSize(width: 10, height: 120),
            isEnabled: true
        ))
        #expect(DownwardDismissGesturePolicy.shouldDismiss(
            translation: CGSize(width: 10, height: 60),
            predictedEndTranslation: CGSize(width: 10, height: 220),
            isEnabled: true
        ))
    }

    @Test("Short, horizontal, upward, and disabled drags stay open")
    func ignoredDismissGestures() {
        #expect(!DownwardDismissGesturePolicy.shouldDismiss(
            translation: CGSize(width: 10, height: 119),
            predictedEndTranslation: CGSize(width: 10, height: 199),
            isEnabled: true
        ))
        #expect(!DownwardDismissGesturePolicy.shouldDismiss(
            translation: CGSize(width: 140, height: 120),
            predictedEndTranslation: CGSize(width: 140, height: 220),
            isEnabled: true
        ))
        #expect(!DownwardDismissGesturePolicy.shouldDismiss(
            translation: CGSize(width: 0, height: -140),
            predictedEndTranslation: CGSize(width: 0, height: -240),
            isEnabled: true
        ))
        #expect(!DownwardDismissGesturePolicy.shouldDismiss(
            translation: CGSize(width: 0, height: 140),
            predictedEndTranslation: CGSize(width: 0, height: 240),
            isEnabled: false
        ))
    }
}

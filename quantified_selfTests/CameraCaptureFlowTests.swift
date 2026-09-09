import Testing
@testable import Quant

struct CameraCaptureFlowTests {
    @Test("Shortcut captures use photos immediately")
    func shortcutUsesPhotoImmediately() {
        #expect(CameraCaptureFlow.forCapture(openedFromShortcut: true) == .useImmediately)
    }

    @Test("Standard captures retain the confirmation step")
    func standardCaptureKeepsConfirmation() {
        #expect(CameraCaptureFlow.forCapture(openedFromShortcut: false) == .confirmBeforeUsing)
    }
}

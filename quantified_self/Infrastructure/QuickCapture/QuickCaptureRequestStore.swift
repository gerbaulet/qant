import Foundation

struct QuickCaptureRequestStore {
    private static let requestKey = "quickCapture.pendingRequest"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func requestCapture() {
        defaults.set(true, forKey: Self.requestKey)
    }

    /// Returns true once for a pending request, then clears it so normal app
    /// activation cannot repeatedly present the capture sheet.
    func consumeCaptureRequest() -> Bool {
        guard defaults.bool(forKey: Self.requestKey) else { return false }
        defaults.removeObject(forKey: Self.requestKey)
        return true
    }
}

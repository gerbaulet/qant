import Foundation
import Testing
@testable import Quant

struct QuickCaptureRequestStoreTests {
    @Test("A quick-capture request is consumed exactly once")
    func consumeOnce() throws {
        let suiteName = "QuickCaptureRequestStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = QuickCaptureRequestStore(defaults: defaults)

        #expect(!store.consumeCaptureRequest())
        store.requestCapture()
        #expect(store.consumeCaptureRequest())
        #expect(!store.consumeCaptureRequest())
    }
}

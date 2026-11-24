import Testing
@testable import Quant

@MainActor
struct IntakeForecastPreferencesTests {
    @Test("The existing forecast remains the default")
    func defaultsToHistoricalRemainder() {
        #expect(IntakeForecastPreferences.strategy(mealAwareEnabled: false) == .historicalRemainder)
        #expect(IntakeForecastPreferences.strategy(mealAwareEnabled: true) == .mealAware)
    }
}

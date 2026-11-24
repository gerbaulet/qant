enum IntakeForecastPreferences {
    nonisolated static let mealAwareEnabledKey = "mealAwareIntakeForecastEnabled"

    nonisolated static func strategy(
        mealAwareEnabled: Bool
    ) -> IntakeForecastStrategy {
        mealAwareEnabled ? .mealAware : .historicalRemainder
    }
}

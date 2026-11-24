import Foundation

enum WeightChartScaleCalculator {
    private static let minimumPaddingKilograms = 0.5
    private static let relativePadding = 0.1

    static func yDomain(
        for comparison: WeightBalanceComparison
    ) -> ClosedRange<Double>? {
        let values = comparison.dailyWeights.map(\.kilograms) +
            comparison.observedTrend.map(\.kilograms) +
            comparison.expectedTrend.map(\.kilograms)
        let finiteValues = values.filter(\.isFinite)
        guard let minimum = finiteValues.min(),
              let maximum = finiteValues.max() else { return nil }

        let padding = max(
            (maximum - minimum) * relativePadding,
            minimumPaddingKilograms
        )
        return (minimum - padding) ... (maximum + padding)
    }
}

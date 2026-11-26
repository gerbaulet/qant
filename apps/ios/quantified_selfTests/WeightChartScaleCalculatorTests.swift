import Foundation
import Testing
@testable import Quant

struct WeightChartScaleCalculatorTests {
    @Test("Weight chart domain includes measured and observed values with padding")
    func includesVisibleSeries() throws {
        let comparison = makeComparison(
            measurements: [79],
            observed: [80, 77]
        )

        let domain = try #require(WeightChartScaleCalculator.yDomain(for: comparison))

        #expect(domain.lowerBound == 76.5)
        #expect(domain.upperBound == 80.5)
        #expect(!domain.contains(0))
    }

    @Test("A flat weight series still receives a readable one kilogram domain")
    func flatSeries() throws {
        let comparison = makeComparison(
            measurements: [80],
            observed: [80]
        )

        let domain = try #require(WeightChartScaleCalculator.yDomain(for: comparison))

        #expect(domain.lowerBound == 79.5)
        #expect(domain.upperBound == 80.5)
    }

    @Test("Missing chart values do not produce an artificial domain")
    func emptySeries() {
        let comparison = makeComparison(
            measurements: [],
            observed: []
        )

        #expect(WeightChartScaleCalculator.yDomain(for: comparison) == nil)
    }

    private func makeComparison(
        measurements: [Double],
        observed: [Double]
    ) -> WeightBalanceComparison {
        let start = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 86_400)
        return WeightBalanceComparison(
            interval: DateInterval(start: start, end: end),
            dailyWeights: measurements.enumerated().map { index, kilograms in
                WeightMeasurement(
                    date: start.addingTimeInterval(Double(index)),
                    kilograms: kilograms
                )
            },
            observedTrend: observed.enumerated().map { index, kilograms in
                WeightChartPoint(
                    date: start.addingTimeInterval(Double(index)),
                    kilograms: kilograms
                )
            },
            observedChangeKilograms: nil,
            readiness: .ready,
            calibrationStatus: .disabled
        )
    }
}

import Foundation
import Testing
@testable import Quant

struct TodayEnergyChartScaleBuilderTests {
    @Test("Mixed energy values fill the chart without an oversized negative range")
    func mixedValuesUseCompactDomain() {
        let trend = makeTrend(
            intake: [0, 2_300],
            expenditure: [0, 2_600],
            balance: [0, -300]
        )

        let scale = TodayEnergyChartScaleBuilder.makeScale(
            for: trend,
            includesAverageIntake: false
        )

        #expect(scale.domain == -3_000...3_000)
        #expect(scale.axisValues == [-3_000, -1_500, 0, 1_500, 3_000])
    }

    @Test("A positive-only trend keeps zero visible and avoids unused negative space")
    func positiveValuesStartAtZero() {
        let trend = makeTrend(intake: [0, 2_300])

        let scale = TodayEnergyChartScaleBuilder.makeScale(
            for: trend,
            includesAverageIntake: false
        )

        #expect(scale.domain == 0...2_500)
        #expect(scale.axisValues == [0, 500, 1_000, 1_500, 2_000, 2_500])
    }

    @Test("The typical intake only affects the scale while it is visible")
    func averageIntakeAffectsVisibleScale() {
        let trend = makeTrend(
            intake: [0, 2_300],
            expenditure: [0, 2_600],
            balance: [0, -300],
            averageIntake: [0, 4_000]
        )

        let hiddenScale = TodayEnergyChartScaleBuilder.makeScale(
            for: trend,
            includesAverageIntake: false
        )
        let visibleScale = TodayEnergyChartScaleBuilder.makeScale(
            for: trend,
            includesAverageIntake: true
        )

        #expect(hiddenScale.domain == -3_000...3_000)
        #expect(visibleScale.domain == -3_000...4_500)
        #expect(visibleScale.axisValues == [-3_000, -1_500, 0, 1_500, 3_000, 4_500])
    }

    @Test("A flat trend receives a stable fallback scale")
    func flatValuesUseFallback() {
        let trend = makeTrend(intake: [0, 0])

        let scale = TodayEnergyChartScaleBuilder.makeScale(
            for: trend,
            includesAverageIntake: false
        )

        #expect(scale.domain == -500...500)
        #expect(scale.axisValues == [-500, -250, 0, 250, 500])
    }

    @Test("Chart height starts compact, grows with width, and remains bounded")
    func responsiveChartHeight() {
        #expect(TodayEnergyChartLayout.height(for: 320) == 210)
        #expect(TodayEnergyChartLayout.height(for: 340) == 210)
        #expect(abs(TodayEnergyChartLayout.height(for: 400) - 247.06) < 0.01)
        #expect(TodayEnergyChartLayout.height(for: 700) == 300)
    }

    private func makeTrend(
        intake: [Double],
        expenditure: [Double] = [],
        balance: [Double] = [],
        averageIntake: [Double] = []
    ) -> TodayEnergyTrend {
        TodayEnergyTrend(
            intakeActualPoints: points(intake),
            intakeForecastPoints: [],
            averageIntakePoints: points(averageIntake),
            expenditureActualPoints: points(expenditure),
            expenditureForecastPoints: [],
            balanceActualPoints: points(balance),
            balanceForecastPoints: [],
            intakeHistoricalDayCount: averageIntake.isEmpty ? 0 : 14,
            expenditureHistoricalDayCount: 14
        )
    }

    private func points(_ values: [Double]) -> [TodayEnergyTrendPoint] {
        values.enumerated().map { index, value in
            TodayEnergyTrendPoint(hour: Double(index) * 24 / Double(max(values.count - 1, 1)), value: value)
        }
    }
}

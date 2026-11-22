import Testing
@testable import Quant

struct TodayEnergyChartLegendBuilderTests {
    @Test("Legend summarizes typical intake and forecast history compactly")
    func summarizesHistoricalSources() {
        let legend = TodayEnergyChartLegendBuilder.makeLegend(
            for: makeTrend(
                averageIntake: [0, 2_100],
                intakeDayCount: 18,
                expenditureDayCount: 42
            )
        )

        #expect(legend.typicalIntakeTitle == "Typisch · 18 Tage")
        #expect(legend.forecastTitle == "Prognose · Verlauf + 42 Tage")
        #expect(legend.balanceTitle == "= Bilanz")
    }

    @Test("Legend omits unavailable typical intake and keeps forecast source concise")
    func handlesMissingHistory() {
        let legend = TodayEnergyChartLegendBuilder.makeLegend(
            for: makeTrend(
                averageIntake: [],
                intakeDayCount: 0,
                expenditureDayCount: 0
            )
        )

        #expect(legend.typicalIntakeTitle == nil)
        #expect(legend.forecastTitle == "Prognose · Tagesverlauf")
        #expect(legend.balanceTitle == "= Bilanz")
    }

    @Test("Legend identifies a personal daily balance adjustment")
    func identifiesPersonalAdjustment() {
        let legend = TodayEnergyChartLegendBuilder.makeLegend(
            for: makeTrend(
                averageIntake: [],
                intakeDayCount: 0,
                expenditureDayCount: 42,
                dailyBalanceAdjustment: 180
            )
        )

        #expect(legend.balanceTitle == "= Bilanz · persönlich (+180/Tag)")
    }

    private func makeTrend(
        averageIntake: [Double],
        intakeDayCount: Int,
        expenditureDayCount: Int,
        dailyBalanceAdjustment: Double? = nil
    ) -> TodayEnergyTrend {
        TodayEnergyTrend(
            intakeActualPoints: [
                .init(hour: 0, value: 0),
                .init(hour: 12, value: 1_000),
            ],
            intakeForecastPoints: [],
            averageIntakePoints: averageIntake.enumerated().map { index, value in
                .init(hour: Double(index) * 24, value: value)
            },
            expenditureActualPoints: [],
            expenditureForecastPoints: [],
            balanceActualPoints: [],
            balanceForecastPoints: [],
            intakeHistoricalDayCount: intakeDayCount,
            expenditureHistoricalDayCount: expenditureDayCount,
            dailyBalanceAdjustmentKilocalories: dailyBalanceAdjustment
        )
    }
}

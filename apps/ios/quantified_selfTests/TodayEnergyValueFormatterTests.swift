import Testing
@testable import Quant

struct TodayEnergyValueFormatterTests {
    @Test("Missing energy values use a dash")
    func missingValue() {
        #expect(TodayEnergyValueFormatter.text(nil) == "—")
    }

    @Test("Only provisional current intake uses an estimate marker")
    func provisionalIntakeMarker() {
        #expect(TodayEnergyValueFormatter.text(785, isProvisional: true) == "~785")
        #expect(TodayEnergyValueFormatter.text(785) == "785")
    }

    @Test("Signed balances do not use an estimate marker")
    func signedBalance() {
        #expect(TodayEnergyValueFormatter.text(-420, showsSign: true) == "−420")
        #expect(TodayEnergyValueFormatter.text(420, showsSign: true) == "+420")
        #expect(TodayEnergyValueFormatter.text(0, showsSign: true) == "0")
    }

    @Test("Current expenditure uses the chart value when the recorded total is unavailable")
    func currentExpenditureUsesTrendFallback() {
        let resolved = TodayEnergyValueResolver.currentExpenditure(
            recorded: nil,
            trendPoints: [
                TodayEnergyTrendPoint(hour: 0, value: 0),
                TodayEnergyTrendPoint(hour: 5.97, value: 394),
            ]
        )

        #expect(resolved == 394)
    }

    @Test("Current expenditure prefers the chart value shown to the user")
    func currentExpenditurePrefersTrend() {
        let resolved = TodayEnergyValueResolver.currentExpenditure(
            recorded: 380,
            trendPoints: [TodayEnergyTrendPoint(hour: 5.97, value: 394)]
        )

        #expect(resolved == 394)
    }

    @Test("Current expenditure remains unavailable without recorded or chart data")
    func currentExpenditureRemainsUnavailable() {
        let resolved = TodayEnergyValueResolver.currentExpenditure(
            recorded: nil,
            trendPoints: [TodayEnergyTrendPoint(hour: 0, value: 0)]
        )

        #expect(resolved == nil)
    }
}

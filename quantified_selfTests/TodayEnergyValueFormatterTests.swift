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
}

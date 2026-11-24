struct TodayEnergyChartLegend: Equatable, Sendable {
    let typicalIntakeTitle: String?
    let forecastTitle: String
    let balanceTitle: String
}

enum TodayEnergyChartLegendBuilder {
    static func makeLegend(for trend: TodayEnergyTrend) -> TodayEnergyChartLegend {
        let typicalIntakeTitle = trend.averageIntakePoints.isEmpty
            ? nil
            : dayCountTitle(prefix: "Typisch", dayCount: trend.intakeHistoricalDayCount)
        let forecastTitle = trend.expenditureHistoricalDayCount > 0
            ? "Prognose · Verlauf + \(trend.expenditureHistoricalDayCount) Tage"
            : "Prognose · Tagesverlauf"
        let balanceTitle = trend.dailyBalanceAdjustmentKilocalories.map {
            "= Bilanz · persönlich (\(signedWholeNumber($0))/Tag)"
        } ?? "= Bilanz"
        return TodayEnergyChartLegend(
            typicalIntakeTitle: typicalIntakeTitle,
            forecastTitle: forecastTitle,
            balanceTitle: balanceTitle
        )
    }

    private static func dayCountTitle(prefix: String, dayCount: Int) -> String {
        guard dayCount > 0 else { return prefix }
        return "\(prefix) · \(dayCount) Tage"
    }

    private static func signedWholeNumber(_ value: Double) -> String {
        let rounded = Int(abs(value).rounded())
        if value < -0.5 { return "−\(rounded)" }
        if value > 0.5 { return "+\(rounded)" }
        return "0"
    }
}

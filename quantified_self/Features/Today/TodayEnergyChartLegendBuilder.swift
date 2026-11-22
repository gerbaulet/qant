struct TodayEnergyChartLegend: Equatable, Sendable {
    let typicalIntakeTitle: String?
    let forecastTitle: String
}

enum TodayEnergyChartLegendBuilder {
    static func makeLegend(for trend: TodayEnergyTrend) -> TodayEnergyChartLegend {
        let typicalIntakeTitle = trend.averageIntakePoints.isEmpty
            ? nil
            : dayCountTitle(prefix: "Typisch", dayCount: trend.intakeHistoricalDayCount)
        let forecastTitle = trend.expenditureHistoricalDayCount > 0
            ? "Prognose · Verlauf + \(trend.expenditureHistoricalDayCount) Tage"
            : "Prognose · Tagesverlauf"
        return TodayEnergyChartLegend(
            typicalIntakeTitle: typicalIntakeTitle,
            forecastTitle: forecastTitle
        )
    }

    private static func dayCountTitle(prefix: String, dayCount: Int) -> String {
        guard dayCount > 0 else { return prefix }
        return "\(prefix) · \(dayCount) Tage"
    }
}

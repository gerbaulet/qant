import Foundation

enum PersonalEnergyBalanceCalculator {
    static func balanceKilocalories(
        for balance: DailyEnergyBalance,
        dailyAdjustmentKilocalories: Double?,
        currentDayForecastKilocalories: Double? = nil
    ) -> Double? {
        guard let recordedBalance = balance.balanceKilocalories else { return nil }
        if balance.isCurrentDay, let currentDayForecastKilocalories {
            return currentDayForecastKilocalories
        }
        guard let dailyAdjustmentKilocalories,
              balance.completeness == .complete,
              !balance.isCurrentDay else {
            return recordedBalance
        }
        return recordedBalance + dailyAdjustmentKilocalories
    }

    static func forecastBalanceKilocalories(
        intakeKilocalories: Double?,
        expenditureKilocalories: Double?,
        dailyAdjustmentKilocalories: Double?
    ) -> Double? {
        guard let intakeKilocalories, let expenditureKilocalories else { return nil }
        return intakeKilocalories
            - expenditureKilocalories
            + (dailyAdjustmentKilocalories ?? 0)
    }

    static func averageBalanceKilocalories(
        for balances: [DailyEnergyBalance],
        dailyAdjustmentKilocalories: Double?
    ) -> Double? {
        let values = balances
            .filter { $0.completeness == .complete && !$0.isCurrentDay }
            .compactMap {
                balanceKilocalories(
                    for: $0,
                    dailyAdjustmentKilocalories: dailyAdjustmentKilocalories
                )
            }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

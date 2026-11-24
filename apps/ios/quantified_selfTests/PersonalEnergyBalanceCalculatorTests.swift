import Foundation
import Testing
@testable import Quant

struct PersonalEnergyBalanceCalculatorTests {
    @Test("Personal adjustment applies only to complete closed days")
    func adjustsOnlyCompleteClosedDays() {
        let complete = balance(
            intake: 1_500,
            completeness: .complete,
            isCurrentDay: false
        )
        let provisional = balance(
            intake: 1_500,
            completeness: .provisionalIntake,
            isCurrentDay: false
        )
        let current = balance(
            intake: 1_500,
            completeness: .complete,
            isCurrentDay: true
        )

        #expect(PersonalEnergyBalanceCalculator.balanceKilocalories(
            for: complete,
            dailyAdjustmentKilocalories: 200
        ) == -300)
        #expect(PersonalEnergyBalanceCalculator.balanceKilocalories(
            for: provisional,
            dailyAdjustmentKilocalories: 200
        ) == -500)
        #expect(PersonalEnergyBalanceCalculator.balanceKilocalories(
            for: current,
            dailyAdjustmentKilocalories: 200
        ) == -500)
    }

    @Test("Personal average uses adjusted complete closed days")
    func adjustedAverage() {
        let balances = [
            balance(intake: 1_500, completeness: .complete, isCurrentDay: false),
            balance(intake: 2_100, completeness: .complete, isCurrentDay: false),
            balance(intake: 1_500, completeness: .complete, isCurrentDay: true),
            balance(intake: 1_500, completeness: .provisionalIntake, isCurrentDay: false),
        ]

        let average = PersonalEnergyBalanceCalculator.averageBalanceKilocalories(
            for: balances,
            dailyAdjustmentKilocalories: 200
        )

        #expect(average == 0)
    }

    @Test("Current day uses its calibrated end-of-day forecast when available")
    func currentDayForecast() {
        let current = balance(
            intake: 1_500,
            completeness: .complete,
            isCurrentDay: true
        )
        let complete = balance(
            intake: 1_500,
            completeness: .complete,
            isCurrentDay: false
        )

        #expect(PersonalEnergyBalanceCalculator.balanceKilocalories(
            for: current,
            dailyAdjustmentKilocalories: 200,
            currentDayForecastKilocalories: -258
        ) == -258)
        #expect(PersonalEnergyBalanceCalculator.balanceKilocalories(
            for: current,
            dailyAdjustmentKilocalories: 200,
            currentDayForecastKilocalories: nil
        ) == -500)
        #expect(PersonalEnergyBalanceCalculator.balanceKilocalories(
            for: complete,
            dailyAdjustmentKilocalories: 200,
            currentDayForecastKilocalories: -258
        ) == -300)
    }

    @Test("Forecast combines projected intake and expenditure with personal adjustment")
    func forecastBalance() {
        #expect(PersonalEnergyBalanceCalculator.forecastBalanceKilocalories(
            intakeKilocalories: 1_956,
            expenditureKilocalories: 2_713,
            dailyAdjustmentKilocalories: 500
        ) == -257)
        #expect(PersonalEnergyBalanceCalculator.forecastBalanceKilocalories(
            intakeKilocalories: 1_956,
            expenditureKilocalories: 2_713,
            dailyAdjustmentKilocalories: nil
        ) == -757)
        #expect(PersonalEnergyBalanceCalculator.forecastBalanceKilocalories(
            intakeKilocalories: nil,
            expenditureKilocalories: 2_713,
            dailyAdjustmentKilocalories: 500
        ) == nil)
    }

    private func balance(
        intake: Double,
        completeness: EnergyBalanceCompleteness,
        isCurrentDay: Bool
    ) -> DailyEnergyBalance {
        DailyEnergyBalance(
            date: Date(timeIntervalSince1970: intake),
            intakeKilocalories: intake,
            activeKilocalories: 400,
            restingKilocalories: 1_600,
            completeness: completeness,
            isCurrentDay: isCurrentDay
        )
    }
}

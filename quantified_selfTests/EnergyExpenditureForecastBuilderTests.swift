import Foundation
import Testing
@testable import Quant

struct EnergyExpenditureForecastBuilderTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    @Test("Forecast adds the weighted historical remainder to today's actual expenditure")
    func forecastsHistoricalRemainder() throws {
        let reference = date(2026, 8, 24, 14, 30)
        let days = (17...23).map { date(2026, 8, $0) }
        let activeRemainders = [100, 200, 300, 400, 500, 600, 700].map(Double.init)
        let restingRemainders = [10, 20, 30, 40, 50, 60, 70].map(Double.init)
        let daily = days.map {
            DailyEnergyExpenditure(
                date: $0,
                activeKilocalories: 900,
                restingKilocalories: 1_600
            )
        }
        let hourly = zip(days.indices, days).flatMap { index, day in
            [
                HourlyEnergyExpenditure(
                    date: calendar.date(byAdding: .hour, value: 8, to: day)!,
                    activeKilocalories: 900 - activeRemainders[index],
                    restingKilocalories: 1_600 - restingRemainders[index]
                ),
                HourlyEnergyExpenditure(
                    date: calendar.date(byAdding: .hour, value: 18, to: day)!,
                    activeKilocalories: activeRemainders[index],
                    restingKilocalories: restingRemainders[index]
                ),
            ]
        }
        let current = DailyEnergyExpenditure(
            date: reference,
            activeKilocalories: 250,
            restingKilocalories: 900
        )

        let forecast = try #require(EnergyExpenditureForecastBuilder.makeForecast(
            for: reference,
            current: current,
            dailyExpenditures: daily,
            hourlyExpenditures: hourly,
            calendar: calendar
        ))

        #expect(forecast.activeKilocalories == 550)
        #expect(forecast.restingKilocalories == 930)
        #expect(forecast.totalKilocalories == 1_480)
        #expect(forecast.historicalDayCount == 7)
        #expect(forecast.method == .historicalRemainder)
    }

    @Test("The current historical hour contributes only its remaining fraction")
    func scalesCurrentHistoricalHour() throws {
        let reference = date(2026, 8, 24, 14, 30)
        let days = (17...23).map { date(2026, 8, $0) }
        let daily = days.map {
            DailyEnergyExpenditure(
                date: $0,
                activeKilocalories: 500,
                restingKilocalories: 1_500
            )
        }
        let hourly = days.flatMap { day in
            [
                HourlyEnergyExpenditure(
                    date: calendar.date(byAdding: .hour, value: 8, to: day)!,
                    activeKilocalories: 400,
                    restingKilocalories: 1_460
                ),
                HourlyEnergyExpenditure(
                    date: calendar.date(byAdding: .hour, value: 14, to: day)!,
                    activeKilocalories: 100,
                    restingKilocalories: 40
                ),
            ]
        }

        let forecast = try #require(EnergyExpenditureForecastBuilder.makeForecast(
            for: reference,
            current: DailyEnergyExpenditure(
                date: reference,
                activeKilocalories: 100,
                restingKilocalories: 600
            ),
            dailyExpenditures: daily,
            hourlyExpenditures: hourly,
            calendar: calendar
        ))

        #expect(forecast.activeKilocalories == 150)
        #expect(forecast.restingKilocalories == 620)
    }

    @Test("Complete daily medians are used when hourly history is unavailable")
    func fallsBackToDailyMedian() throws {
        let reference = date(2026, 8, 24, 14)
        let days = (17...23).map { date(2026, 8, $0) }
        let daily = days.enumerated().map { index, day in
            DailyEnergyExpenditure(
                date: day,
                activeKilocalories: Double(400 + index * 100),
                restingKilocalories: Double(1_500 + index * 100)
            )
        }

        let forecast = try #require(EnergyExpenditureForecastBuilder.makeForecast(
            for: reference,
            current: DailyEnergyExpenditure(
                date: reference,
                activeKilocalories: 250,
                restingKilocalories: 900
            ),
            dailyExpenditures: daily,
            hourlyExpenditures: [],
            calendar: calendar
        ))

        #expect(forecast.activeKilocalories == 600)
        #expect(forecast.restingKilocalories == 1_700)
        #expect(forecast.historicalDayCount == 7)
        #expect(forecast.method == .dailyMedian)
    }

    @Test("Forecast requires seven complete historical expenditure days")
    func requiresSevenCompleteDays() {
        let reference = date(2026, 8, 24, 14)
        let daily = (18...23).map {
            DailyEnergyExpenditure(
                date: date(2026, 8, $0),
                activeKilocalories: 500,
                restingKilocalories: 1_500
            )
        }

        let forecast = EnergyExpenditureForecastBuilder.makeForecast(
            for: reference,
            current: DailyEnergyExpenditure(
                date: reference,
                activeKilocalories: 250,
                restingKilocalories: 900
            ),
            dailyExpenditures: daily,
            hourlyExpenditures: [],
            calendar: calendar
        )

        #expect(forecast == nil)
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }
}

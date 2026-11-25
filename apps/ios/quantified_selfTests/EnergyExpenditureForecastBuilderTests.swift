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

    @Test("Forecast rejects incomplete current resting energy")
    func rejectsIncompleteCurrentRestingEnergy() {
        let reference = date(2026, 8, 24, 20)
        let daily = (17...23).map {
            DailyEnergyExpenditure(
                date: date(2026, 8, $0),
                activeKilocalories: 500,
                restingKilocalories: 1_500
            )
        }
        let current = DailyEnergyExpenditure(
            date: reference,
            activeKilocalories: 250,
            restingKilocalories: 900,
            restingEnergyCoverage: RestingEnergyCoverage(
                expectedDuration: 20 * 60 * 60,
                primaryDuration: 2 * 60 * 60,
                iPhoneFallbackDuration: 0
            )
        )

        let forecast = EnergyExpenditureForecastBuilder.makeForecast(
            for: reference,
            current: current,
            dailyExpenditures: daily,
            hourlyExpenditures: [],
            calendar: calendar
        )

        #expect(forecast == nil)
    }

    @Test("Forecast tolerates an eight-hour current resting energy gap")
    func toleratesOvernightCurrentRestingEnergyGap() throws {
        let reference = date(2026, 8, 24, 14)
        let daily = (17...23).map {
            DailyEnergyExpenditure(
                date: date(2026, 8, $0),
                activeKilocalories: 500,
                restingKilocalories: 1_500
            )
        }
        let current = DailyEnergyExpenditure(
            date: reference,
            activeKilocalories: 250,
            restingKilocalories: 900,
            restingEnergyCoverage: RestingEnergyCoverage(
                expectedDuration: 14 * 60 * 60,
                primaryDuration: 6 * 60 * 60,
                iPhoneFallbackDuration: 0
            )
        )

        let forecast = try #require(EnergyExpenditureForecastBuilder.makeForecast(
            for: reference,
            current: current,
            dailyExpenditures: daily,
            hourlyExpenditures: [],
            calendar: calendar
        ))

        #expect(forecast.activeKilocalories == 500)
        #expect(forecast.restingKilocalories == 1_500)
        #expect(forecast.historicalDayCount == 7)
    }

    @Test("Forecast treats missing current active energy as zero when history is sufficient")
    func forecastsWithoutCurrentActiveEnergy() throws {
        let reference = date(2026, 8, 24, 4)
        let daily = (17...23).map {
            DailyEnergyExpenditure(
                date: date(2026, 8, $0),
                activeKilocalories: 500,
                restingKilocalories: 1_500
            )
        }
        let current = DailyEnergyExpenditure(
            date: reference,
            activeKilocalories: nil,
            restingKilocalories: 300,
            restingEnergyCoverage: RestingEnergyCoverage(
                expectedDuration: 4 * 60 * 60,
                primaryDuration: 0,
                iPhoneFallbackDuration: 0,
                estimatedDuration: 4 * 60 * 60
            )
        )

        let forecast = try #require(EnergyExpenditureForecastBuilder.makeForecast(
            for: reference,
            current: current,
            dailyExpenditures: daily,
            hourlyExpenditures: [],
            calendar: calendar
        ))

        #expect(forecast.activeKilocalories == 500)
        #expect(forecast.restingKilocalories == 1_500)
        #expect(forecast.historicalDayCount == 7)
        #expect(forecast.method == .dailyMedian)
    }

    @Test("Forecast excludes incomplete historical resting energy")
    func excludesIncompleteHistoricalRestingEnergy() {
        let reference = date(2026, 8, 24, 14)
        let daily = (17...23).map { day in
            DailyEnergyExpenditure(
                date: date(2026, 8, day),
                activeKilocalories: 500,
                restingKilocalories: 1_500,
                restingEnergyCoverage: day == 17
                    ? RestingEnergyCoverage(
                        expectedDuration: 24 * 60 * 60,
                        primaryDuration: 20 * 60 * 60,
                        iPhoneFallbackDuration: 0
                    )
                    : nil
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

    @Test("Forecast includes historical days completed by personal estimates")
    func includesEstimatedHistoricalRestingEnergy() throws {
        let reference = date(2026, 8, 24, 14)
        let daily = (17...23).map { day in
            DailyEnergyExpenditure(
                date: date(2026, 8, day),
                activeKilocalories: 500,
                restingKilocalories: 1_500,
                estimatedRestingKilocalories: 1_000,
                restingEnergyCoverage: RestingEnergyCoverage(
                    expectedDuration: 24 * 60 * 60,
                    primaryDuration: 8 * 60 * 60,
                    iPhoneFallbackDuration: 0,
                    estimatedDuration: 16 * 60 * 60
                )
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

        #expect(forecast.historicalDayCount == 7)
        #expect(forecast.restingKilocalories == 1_500)
    }

    @Test("Forecast history covers ninety calendar days through the selected day")
    func historyIntervalUsesCalendarDays() throws {
        let reference = date(2026, 3, 30, 14)
        let selectedDay = try #require(calendar.dateInterval(of: .day, for: reference))
        let interval = try #require(EnergyExpenditureForecastBuilder.historyInterval(
            for: reference,
            calendar: calendar
        ))

        #expect(interval.start == calendar.date(
            byAdding: .day,
            value: -90,
            to: selectedDay.start
        ))
        #expect(interval.end == selectedDay.end)
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

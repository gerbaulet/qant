import Foundation
import Testing
@testable import Quant

struct TodayEnergyTrendBuilderTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    @Test("The trend combines current and forecast intake with negative expenditure balance")
    func combinesIntakeAndExpenditure() throws {
        let now = date(2026, 11, 22, 18, 30)
        let intake = DailyCumulativeNutritionTrend(
            actualPoints: [
                .init(hour: 0, value: 0),
                .init(hour: 12, value: 1_200),
                .init(hour: 18.5, value: 1_680),
            ],
            averagePoints: [
                .init(hour: 0, value: 0),
                .init(hour: 24, value: 2_200),
            ],
            forecastPoints: [
                .init(hour: 18.5, value: 1_680),
                .init(hour: 20, value: 2_100),
                .init(hour: 24, value: 2_330),
            ],
            hasActualData: true,
            averageDayCount: 81,
            forecastDayCount: 81,
            hasProvisionalValues: false
        )
        let historicalHours = (15...21).flatMap { day in
            [
                HourlyEnergyExpenditure(
                    date: date(2026, 11, day, 19),
                    activeKilocalories: 80,
                    restingKilocalories: 70
                ),
                HourlyEnergyExpenditure(
                    date: date(2026, 11, day, 22),
                    activeKilocalories: 20,
                    restingKilocalories: 70
                ),
            ]
        }
        let currentHours = [
            HourlyEnergyExpenditure(
                date: date(2026, 11, 22, 8),
                activeKilocalories: 300,
                restingKilocalories: 650
            ),
            HourlyEnergyExpenditure(
                date: date(2026, 11, 22, 17),
                activeKilocalories: 420,
                restingKilocalories: 620
            ),
        ]

        let trend = TodayEnergyTrendBuilder.makeTrend(
            intakeTrend: intake,
            currentExpenditure: DailyEnergyExpenditure(
                date: now,
                activeKilocalories: 720,
                restingKilocalories: 1_270
            ),
            expenditureForecast: EnergyExpenditureForecast(
                activeKilocalories: 950,
                restingKilocalories: 1_750,
                historicalDayCount: 42,
                method: .historicalRemainder
            ),
            hourlyExpenditures: historicalHours + currentHours,
            now: now,
            calendar: calendar
        )

        #expect(trend.hasChartData)
        #expect(trend.intakeHistoricalDayCount == 81)
        #expect(trend.expenditureHistoricalDayCount == 42)
        #expect(trend.expenditureActualPoints.last?.hour == 18.5)
        #expect(trend.expenditureActualPoints.last?.value == 1_990)
        #expect(trend.balanceActualPoints.last?.value == -310)
        #expect(trend.intakeForecastPoints.last?.value == 2_330)
        #expect(trend.expenditureForecastPoints.last?.hour == 24)
        #expect(trend.expenditureForecastPoints.last?.value == 2_700)
        #expect(trend.balanceForecastPoints.last?.value == -370)
    }

    @Test("Missing forecasts keep the current trend without inventing future values")
    func omitsUnavailableForecast() {
        let now = date(2026, 11, 22, 12)
        let intake = DailyCumulativeNutritionTrend(
            actualPoints: [
                .init(hour: 0, value: 0),
                .init(hour: 12, value: 900),
            ],
            averagePoints: [],
            forecastPoints: [],
            hasActualData: true,
            averageDayCount: 0,
            forecastDayCount: 0,
            hasProvisionalValues: false
        )

        let trend = TodayEnergyTrendBuilder.makeTrend(
            intakeTrend: intake,
            currentExpenditure: DailyEnergyExpenditure(
                date: now,
                activeKilocalories: 300,
                restingKilocalories: 800
            ),
            expenditureForecast: nil,
            hourlyExpenditures: [],
            now: now,
            calendar: calendar
        )

        #expect(trend.expenditureActualPoints.last?.value == 1_100)
        #expect(trend.balanceActualPoints.last?.value == -200)
        #expect(trend.expenditureForecastPoints.isEmpty)
        #expect(trend.balanceForecastPoints.isEmpty)
    }

    @Test("A forecast starting on a full hour has unique chart points")
    func fullHourForecastHasUniquePoints() {
        let now = date(2026, 11, 22, 18)
        let intake = DailyCumulativeNutritionTrend(
            actualPoints: [
                .init(hour: 0, value: 0),
                .init(hour: 18, value: 1_500),
            ],
            averagePoints: [],
            forecastPoints: [
                .init(hour: 18, value: 1_500),
                .init(hour: 24, value: 2_000),
            ],
            hasActualData: true,
            averageDayCount: 0,
            forecastDayCount: 7,
            hasProvisionalValues: false
        )

        let trend = TodayEnergyTrendBuilder.makeTrend(
            intakeTrend: intake,
            currentExpenditure: DailyEnergyExpenditure(
                date: now,
                activeKilocalories: 600,
                restingKilocalories: 1_200
            ),
            expenditureForecast: EnergyExpenditureForecast(
                activeKilocalories: 800,
                restingKilocalories: 1_600,
                historicalDayCount: 7,
                method: .historicalRemainder
            ),
            hourlyExpenditures: [],
            now: now,
            calendar: calendar
        )

        #expect(trend.expenditureForecastPoints.first?.hour == 18)
        #expect(trend.expenditureForecastPoints.dropFirst().first?.hour == 19)
        #expect(Set(trend.expenditureForecastPoints.map(\.id)).count == trend.expenditureForecastPoints.count)
        #expect(trend.expenditureForecastPoints.last?.value == 2_400)
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

import Foundation

enum EnergyExpenditureForecastBuilder {
    private struct WeightedValue {
        let value: Double
        let weight: Double
    }

    private struct HistoricalDay {
        let date: Date
        let activeKilocalories: Double
        let restingKilocalories: Double
        let weight: Double
    }

    private static let minimumHistoricalDayCount = 7
    private static let maximumHistoricalDayCount = 90

    static func historyInterval(
        for date: Date,
        calendar: Calendar
    ) -> DateInterval? {
        guard let dayInterval = calendar.dateInterval(of: .day, for: date),
              let start = calendar.date(
                byAdding: .day,
                value: -maximumHistoricalDayCount,
                to: dayInterval.start
              ) else {
            return nil
        }
        return DateInterval(start: start, end: dayInterval.end)
    }

    static func makeForecast(
        for date: Date,
        current: DailyEnergyExpenditure?,
        dailyExpenditures: [DailyEnergyExpenditure],
        hourlyExpenditures: [HourlyEnergyExpenditure],
        calendar: Calendar
    ) -> EnergyExpenditureForecast? {
        guard let currentResting = current?.restingKilocalories,
              current?.restingEnergyCoverage?.isUsableForLiveFeatures != false else {
            return nil
        }
        let currentActive = current?.activeKilocalories ?? 0

        let selectedDay = calendar.startOfDay(for: date)
        let selectedWeekday = calendar.component(.weekday, from: selectedDay)
        let dailyByDay = Dictionary(
            dailyExpenditures.compactMap { expenditure -> (Date, DailyEnergyExpenditure)? in
                let day = calendar.startOfDay(for: expenditure.date)
                guard day < selectedDay,
                      expenditure.activeKilocalories != nil,
                      expenditure.restingKilocalories != nil,
                      expenditure.restingEnergyCoverage?.isComplete != false else {
                    return nil
                }
                return (day, expenditure)
            },
            uniquingKeysWith: { _, newest in newest }
        )
        let historicalDays = dailyByDay
            .sorted { $0.key > $1.key }
            .prefix(maximumHistoricalDayCount)
            .compactMap { day, expenditure -> HistoricalDay? in
                guard let active = expenditure.activeKilocalories,
                      let resting = expenditure.restingKilocalories else {
                    return nil
                }
                return HistoricalDay(
                    date: day,
                    activeKilocalories: active,
                    restingKilocalories: resting,
                    weight: calendar.component(.weekday, from: day) == selectedWeekday ? 2 : 1
                )
            }
        guard historicalDays.count >= minimumHistoricalDayCount else { return nil }

        let hourlyByDay = Dictionary(grouping: hourlyExpenditures) {
            calendar.startOfDay(for: $0.date)
        }
        let currentHour = localHour(for: date, calendar: calendar)
        let remainderDays = historicalDays.compactMap { day -> HistoricalDay? in
            guard let hourly = hourlyByDay[day.date],
                  hourly.contains(where: { $0.activeKilocalories != nil }),
                  hourly.contains(where: { $0.restingKilocalories != nil }),
                  !hourly.contains(where: {
                      $0.restingEnergyCoverage?.isComplete == false
                  }),
                  totalsMatch(
                    actual: hourly.compactMap(\.activeKilocalories).reduce(0, +),
                    expected: day.activeKilocalories
                  ),
                  totalsMatch(
                    actual: hourly.compactMap(\.restingKilocalories).reduce(0, +),
                    expected: day.restingKilocalories
                  ) else {
                return nil
            }
            let active = hourly.reduce(0) { total, expenditure in
                total + (expenditure.activeKilocalories ?? 0) * remainingFraction(
                    after: currentHour,
                    for: expenditure.date,
                    calendar: calendar
                )
            }
            let resting = hourly.reduce(0) { total, expenditure in
                total + (expenditure.restingKilocalories ?? 0) * remainingFraction(
                    after: currentHour,
                    for: expenditure.date,
                    calendar: calendar
                )
            }
            return HistoricalDay(
                date: day.date,
                activeKilocalories: active,
                restingKilocalories: resting,
                weight: day.weight
            )
        }

        if remainderDays.count >= minimumHistoricalDayCount,
           let activeRemainder = weightedMedian(remainderDays.map {
               WeightedValue(value: $0.activeKilocalories, weight: $0.weight)
           }),
           let restingRemainder = weightedMedian(remainderDays.map {
               WeightedValue(value: $0.restingKilocalories, weight: $0.weight)
           }) {
            return EnergyExpenditureForecast(
                activeKilocalories: max(currentActive + activeRemainder, currentActive),
                restingKilocalories: max(currentResting + restingRemainder, currentResting),
                historicalDayCount: remainderDays.count,
                method: .historicalRemainder
            )
        }

        guard let activeMedian = weightedMedian(historicalDays.map {
            WeightedValue(value: $0.activeKilocalories, weight: $0.weight)
        }),
        let restingMedian = weightedMedian(historicalDays.map {
            WeightedValue(value: $0.restingKilocalories, weight: $0.weight)
        }) else {
            return nil
        }
        return EnergyExpenditureForecast(
            activeKilocalories: max(activeMedian, currentActive),
            restingKilocalories: max(restingMedian, currentResting),
            historicalDayCount: historicalDays.count,
            method: .dailyMedian
        )
    }

    private static func remainingFraction(
        after currentHour: Double,
        for date: Date,
        calendar: Calendar
    ) -> Double {
        let bucketStart = localHour(for: date, calendar: calendar)
        return min(max(bucketStart + 1 - currentHour, 0), 1)
    }

    private static func localHour(for date: Date, calendar: Calendar) -> Double {
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double(components.hour ?? 0)
            + Double(components.minute ?? 0) / 60
            + Double(components.second ?? 0) / 3_600
    }

    private static func weightedMedian(_ values: [WeightedValue]) -> Double? {
        let sorted = values
            .filter { $0.weight > 0 && $0.value.isFinite }
            .sorted { $0.value < $1.value }
        let totalWeight = sorted.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return nil }
        let threshold = totalWeight / 2
        var accumulatedWeight = 0.0
        for value in sorted {
            accumulatedWeight += value.weight
            if accumulatedWeight >= threshold {
                return value.value
            }
        }
        return sorted.last?.value
    }

    private static func totalsMatch(actual: Double, expected: Double) -> Bool {
        abs(actual - expected) <= max(abs(expected) * 0.02, 1)
    }
}

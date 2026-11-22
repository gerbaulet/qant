import Foundation

struct TodayEnergyTrendPoint: Identifiable, Sendable, Equatable {
    let hour: Double
    let value: Double

    var id: Double { hour }
}

struct TodayEnergyTrend: Sendable, Equatable {
    let intakeActualPoints: [TodayEnergyTrendPoint]
    let intakeForecastPoints: [TodayEnergyTrendPoint]
    let averageIntakePoints: [TodayEnergyTrendPoint]
    let expenditureActualPoints: [TodayEnergyTrendPoint]
    let expenditureForecastPoints: [TodayEnergyTrendPoint]
    let balanceActualPoints: [TodayEnergyTrendPoint]
    let balanceForecastPoints: [TodayEnergyTrendPoint]
    let intakeHistoricalDayCount: Int
    let expenditureHistoricalDayCount: Int
    let dailyBalanceAdjustmentKilocalories: Double?

    init(
        intakeActualPoints: [TodayEnergyTrendPoint],
        intakeForecastPoints: [TodayEnergyTrendPoint],
        averageIntakePoints: [TodayEnergyTrendPoint],
        expenditureActualPoints: [TodayEnergyTrendPoint],
        expenditureForecastPoints: [TodayEnergyTrendPoint],
        balanceActualPoints: [TodayEnergyTrendPoint],
        balanceForecastPoints: [TodayEnergyTrendPoint],
        intakeHistoricalDayCount: Int,
        expenditureHistoricalDayCount: Int,
        dailyBalanceAdjustmentKilocalories: Double? = nil
    ) {
        self.intakeActualPoints = intakeActualPoints
        self.intakeForecastPoints = intakeForecastPoints
        self.averageIntakePoints = averageIntakePoints
        self.expenditureActualPoints = expenditureActualPoints
        self.expenditureForecastPoints = expenditureForecastPoints
        self.balanceActualPoints = balanceActualPoints
        self.balanceForecastPoints = balanceForecastPoints
        self.intakeHistoricalDayCount = intakeHistoricalDayCount
        self.expenditureHistoricalDayCount = expenditureHistoricalDayCount
        self.dailyBalanceAdjustmentKilocalories = dailyBalanceAdjustmentKilocalories
    }

    var hasChartData: Bool {
        intakeActualPoints.count > 1 || expenditureActualPoints.count > 1
    }
}

enum TodayEnergyTrendBuilder {
    static func makeTrend(
        intakeTrend: DailyCumulativeNutritionTrend,
        currentExpenditure: DailyEnergyExpenditure?,
        expenditureForecast: EnergyExpenditureForecast?,
        hourlyExpenditures: [HourlyEnergyExpenditure],
        dailyBalanceAdjustmentKilocalories: Double? = nil,
        now: Date,
        calendar: Calendar
    ) -> TodayEnergyTrend {
        let intakeActual = intakeTrend.actualPoints.map {
            TodayEnergyTrendPoint(hour: $0.hour, value: $0.value)
        }
        let intakeForecast = intakeTrend.forecastPoints.map {
            TodayEnergyTrendPoint(hour: $0.hour, value: $0.value)
        }
        let averageIntake = intakeTrend.averagePoints.map {
            TodayEnergyTrendPoint(hour: $0.hour, value: $0.value)
        }
        let expenditureActual = makeActualExpenditurePoints(
            current: currentExpenditure,
            hourlyExpenditures: hourlyExpenditures,
            now: now,
            calendar: calendar
        )
        let expenditureForecastPoints = makeForecastExpenditurePoints(
            actualPoints: expenditureActual,
            forecast: expenditureForecast,
            hourlyExpenditures: hourlyExpenditures,
            now: now,
            calendar: calendar
        )
        let appliedDailyAdjustment = expenditureForecast == nil
            ? nil
            : dailyBalanceAdjustmentKilocalories

        return TodayEnergyTrend(
            intakeActualPoints: intakeActual,
            intakeForecastPoints: intakeForecast,
            averageIntakePoints: averageIntake,
            expenditureActualPoints: expenditureActual,
            expenditureForecastPoints: expenditureForecastPoints,
            balanceActualPoints: makeBalancePoints(
                intake: intakeActual,
                expenditure: expenditureActual,
                dailyBalanceAdjustmentKilocalories: appliedDailyAdjustment,
                forecastExpenditureKilocalories: expenditureForecast?.totalKilocalories
            ),
            balanceForecastPoints: makeBalancePoints(
                intake: intakeForecast,
                expenditure: expenditureForecastPoints,
                dailyBalanceAdjustmentKilocalories: appliedDailyAdjustment,
                forecastExpenditureKilocalories: expenditureForecast?.totalKilocalories
            ),
            intakeHistoricalDayCount: intakeTrend.averageDayCount,
            expenditureHistoricalDayCount: expenditureForecast?.historicalDayCount ?? 0,
            dailyBalanceAdjustmentKilocalories: appliedDailyAdjustment
        )
    }

    private static func makeActualExpenditurePoints(
        current: DailyEnergyExpenditure?,
        hourlyExpenditures: [HourlyEnergyExpenditure],
        now: Date,
        calendar: Calendar
    ) -> [TodayEnergyTrendPoint] {
        guard let day = calendar.dateInterval(of: .day, for: now) else { return [] }
        let currentHour = localHour(for: now, calendar: calendar)
        var valuesByPointHour: [Double: Double] = [:]
        for expenditure in hourlyExpenditures where
            expenditure.date >= day.start && expenditure.date < day.end && expenditure.date <= now
        {
            guard expenditure.activeKilocalories != nil || expenditure.restingKilocalories != nil else {
                continue
            }
            let bucketStart = localHour(for: expenditure.date, calendar: calendar)
            let pointHour = min(bucketStart + 1, currentHour)
            valuesByPointHour[pointHour, default: 0] +=
                (expenditure.activeKilocalories ?? 0) + (expenditure.restingKilocalories ?? 0)
        }

        var cumulative = 0.0
        var points = [TodayEnergyTrendPoint(hour: 0, value: 0)]
        for hour in valuesByPointHour.keys.sorted() where hour > 0 {
            cumulative += valuesByPointHour[hour, default: 0]
            points.append(TodayEnergyTrendPoint(hour: hour, value: cumulative))
        }
        if let total = current?.totalKilocalories, currentHour > 0 {
            if points.last?.hour == currentHour {
                points[points.count - 1] = TodayEnergyTrendPoint(hour: currentHour, value: total)
            } else {
                points.append(TodayEnergyTrendPoint(hour: currentHour, value: total))
            }
        }
        return points.sorted { $0.hour < $1.hour }
    }

    private static func makeForecastExpenditurePoints(
        actualPoints: [TodayEnergyTrendPoint],
        forecast: EnergyExpenditureForecast?,
        hourlyExpenditures: [HourlyEnergyExpenditure],
        now: Date,
        calendar: Calendar
    ) -> [TodayEnergyTrendPoint] {
        guard let forecast,
              let currentValue = actualPoints.last?.value else { return [] }
        let currentHour = min(localHour(for: now, calendar: calendar), 24)
        guard currentHour < 24 else {
            return [TodayEnergyTrendPoint(hour: 24, value: currentValue)]
        }
        let boundaries = futureHourBoundaries(after: currentHour)
        let weights = forecastWeights(
            for: boundaries,
            after: currentHour,
            hourlyExpenditures: hourlyExpenditures,
            now: now,
            calendar: calendar
        )
        let totalWeight = weights.values.reduce(0, +)
        let remaining = max(forecast.totalKilocalories - currentValue, 0)
        var cumulative = currentValue
        var points = [TodayEnergyTrendPoint(hour: currentHour, value: currentValue)]
        for boundary in boundaries {
            let share = totalWeight > 0
                ? weights[boundary, default: 0] / totalWeight
                : 1 / Double(boundaries.count)
            cumulative += remaining * share
            points.append(TodayEnergyTrendPoint(hour: boundary, value: cumulative))
        }
        if let lastIndex = points.indices.last {
            points[lastIndex] = TodayEnergyTrendPoint(
                hour: 24,
                value: forecast.totalKilocalories
            )
        }
        return points
    }

    private static func futureHourBoundaries(after currentHour: Double) -> [Double] {
        let first = max(Int(floor(currentHour)) + 1, 1)
        return (first...24).map(Double.init)
    }

    private static func forecastWeights(
        for boundaries: [Double],
        after currentHour: Double,
        hourlyExpenditures: [HourlyEnergyExpenditure],
        now: Date,
        calendar: Calendar
    ) -> [Double: Double] {
        let today = calendar.startOfDay(for: now)
        var valuesByBoundary: [Double: [Double]] = [:]
        for expenditure in hourlyExpenditures {
            guard calendar.startOfDay(for: expenditure.date) < today,
                  expenditure.activeKilocalories != nil || expenditure.restingKilocalories != nil else {
                continue
            }
            let bucketStart = localHour(for: expenditure.date, calendar: calendar)
            let boundary = min(floor(bucketStart) + 1, 24)
            guard boundaries.contains(boundary) else { continue }
            let fraction = boundary == boundaries.first
                ? min(max(boundary - currentHour, 0), 1)
                : 1
            let value = ((expenditure.activeKilocalories ?? 0) +
                (expenditure.restingKilocalories ?? 0)) * fraction
            valuesByBoundary[boundary, default: []].append(value)
        }
        return Dictionary(uniqueKeysWithValues: boundaries.map { boundary in
            let values = valuesByBoundary[boundary, default: []]
            let historicalAverage = values.isEmpty
                ? nil
                : values.reduce(0, +) / Double(values.count)
            let fallback = boundary == boundaries.first
                ? max(boundary - currentHour, 0.01)
                : 1
            return (boundary, max(historicalAverage ?? fallback, 0.01))
        })
    }

    private static func makeBalancePoints(
        intake: [TodayEnergyTrendPoint],
        expenditure: [TodayEnergyTrendPoint],
        dailyBalanceAdjustmentKilocalories: Double?,
        forecastExpenditureKilocalories: Double?
    ) -> [TodayEnergyTrendPoint] {
        guard !intake.isEmpty, !expenditure.isEmpty else { return [] }
        let hours = Set(intake.map(\.hour)).union(expenditure.map(\.hour)).sorted()
        return hours.compactMap { hour in
            guard let intakeValue = value(at: hour, in: intake),
                  let expenditureValue = value(at: hour, in: expenditure) else { return nil }
            let adjustment = progressiveAdjustment(
                expenditureKilocalories: expenditureValue,
                dailyBalanceAdjustmentKilocalories: dailyBalanceAdjustmentKilocalories,
                forecastExpenditureKilocalories: forecastExpenditureKilocalories
            )
            return TodayEnergyTrendPoint(
                hour: hour,
                value: intakeValue - expenditureValue + adjustment
            )
        }
    }

    private static func progressiveAdjustment(
        expenditureKilocalories: Double,
        dailyBalanceAdjustmentKilocalories: Double?,
        forecastExpenditureKilocalories: Double?
    ) -> Double {
        guard let dailyBalanceAdjustmentKilocalories,
              let forecastExpenditureKilocalories,
              forecastExpenditureKilocalories > 0 else { return 0 }
        let expenditureShare = min(
            max(expenditureKilocalories / forecastExpenditureKilocalories, 0),
            1
        )
        return dailyBalanceAdjustmentKilocalories * expenditureShare
    }

    private static func value(
        at hour: Double,
        in points: [TodayEnergyTrendPoint]
    ) -> Double? {
        points.last(where: { $0.hour <= hour })?.value
    }

    private static func localHour(for date: Date, calendar: Calendar) -> Double {
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double(components.hour ?? 0) +
            Double(components.minute ?? 0) / 60 +
            Double(components.second ?? 0) / 3_600
    }
}

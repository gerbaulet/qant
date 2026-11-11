import Foundation

enum WeightBalanceComparisonBuilder {
    static let comparisonDayCount = 28
    static let minimumComparisonWeightCount = 4
    static let minimumComparisonWeightSpanDays = 21
    static let minimumComparisonBalanceDayCount = 21
    static let minimumCalibrationWeightCount = 12
    static let minimumCalibrationWeightSpanDays = 42
    static let minimumCalibrationBalanceDayCount = 42
    static let kilocaloriesPerKilogram = 7_700.0

    static func makeComparison(
        measurements: [WeightMeasurement],
        balances: [DailyEnergyBalance],
        now: Date,
        calendar: Calendar,
        calibrationEnabled: Bool
    ) -> WeightBalanceComparison {
        let today = calendar.startOfDay(for: now)
        let comparisonStart = calendar.date(
            byAdding: .day,
            value: -comparisonDayCount,
            to: today
        ) ?? today
        let interval = DateInterval(start: comparisonStart, end: today)
        let dailyWeights = dailyMedians(
            measurements.filter { $0.date >= comparisonStart && $0.date <= now },
            calendar: calendar
        )
        let comparisonBalances = balances.filter {
            $0.date >= comparisonStart &&
                $0.date < today &&
                $0.completeness == .complete
        }
        let calibrationStatus = makeCalibrationStatus(
            measurements: measurements,
            balances: balances,
            trainingEnd: comparisonStart,
            calendar: calendar,
            enabled: calibrationEnabled
        )

        let weightSpan = spanDays(for: dailyWeights, calendar: calendar)
        let readiness: WeightComparisonReadiness
        if dailyWeights.count < minimumComparisonWeightCount ||
            weightSpan < minimumComparisonWeightSpanDays {
            readiness = .needsWeights(
                current: dailyWeights.count,
                required: minimumComparisonWeightCount,
                spanDays: weightSpan,
                requiredSpanDays: minimumComparisonWeightSpanDays
            )
        } else if comparisonBalances.count < minimumComparisonBalanceDayCount {
            readiness = .needsBalanceDays(
                current: comparisonBalances.count,
                required: minimumComparisonBalanceDayCount
            )
        } else {
            readiness = .ready
        }

        guard let line = trendLine(for: dailyWeights, calendar: calendar) else {
            return WeightBalanceComparison(
                interval: interval,
                dailyWeights: dailyWeights,
                observedTrend: [],
                expectedTrend: [],
                observedChangeKilograms: nil,
                expectedChangeKilograms: nil,
                evaluableBalanceDayCount: comparisonBalances.count,
                readiness: readiness,
                calibrationStatus: calibrationStatus
            )
        }

        let intervalDays = calendar.dateComponents(
            [.day],
            from: comparisonStart,
            to: today
        ).day ?? comparisonDayCount
        let observedStart = line.value(on: comparisonStart, calendar: calendar)
        let observedEnd = line.value(on: today, calendar: calendar)
        let factor: Double
        if case let .ready(calibratedFactor) = calibrationStatus {
            factor = calibratedFactor
        } else {
            factor = 1
        }
        let expectedTrend = makeExpectedTrend(
            startDate: comparisonStart,
            endDate: today,
            startingWeight: observedStart,
            balances: comparisonBalances,
            factor: factor,
            calendar: calendar
        )

        return WeightBalanceComparison(
            interval: interval,
            dailyWeights: dailyWeights,
            observedTrend: [
                WeightChartPoint(date: comparisonStart, kilograms: observedStart),
                WeightChartPoint(date: today, kilograms: observedEnd),
            ],
            expectedTrend: expectedTrend,
            observedChangeKilograms: line.slopeKilogramsPerDay * Double(intervalDays),
            expectedChangeKilograms: expectedTrend.last.map { $0.kilograms - observedStart },
            evaluableBalanceDayCount: comparisonBalances.count,
            readiness: readiness,
            calibrationStatus: calibrationStatus
        )
    }

    static func dailyMedians(
        _ measurements: [WeightMeasurement],
        calendar: Calendar
    ) -> [WeightMeasurement] {
        Dictionary(grouping: measurements) {
            calendar.startOfDay(for: $0.date)
        }
        .map { day, values in
            WeightMeasurement(
                id: values.sorted { $0.id.uuidString < $1.id.uuidString }.first?.id ?? UUID(),
                date: day,
                kilograms: median(values.map(\.kilograms)) ?? 0
            )
        }
        .sorted { $0.date < $1.date }
    }

    private static func makeCalibrationStatus(
        measurements: [WeightMeasurement],
        balances: [DailyEnergyBalance],
        trainingEnd: Date,
        calendar: Calendar,
        enabled: Bool
    ) -> PersonalCalibrationStatus {
        guard enabled else { return .disabled }
        let trainingWeights = dailyMedians(
            measurements.filter { $0.date < trainingEnd },
            calendar: calendar
        )
        let firstTrainingDate = trainingWeights.first?.date
        let lastTrainingDate = trainingWeights.last?.date
        let trainingBalances = balances.filter { balance in
            guard let firstTrainingDate, let lastTrainingDate else { return false }
            return balance.date >= firstTrainingDate &&
                balance.date < lastTrainingDate &&
                balance.date < trainingEnd &&
                balance.completeness == .complete
        }
        let weightSpan = spanDays(for: trainingWeights, calendar: calendar)
        guard trainingWeights.count >= minimumCalibrationWeightCount,
              trainingBalances.count >= minimumCalibrationBalanceDayCount,
              weightSpan >= minimumCalibrationWeightSpanDays else {
            return .collecting(
                weightCount: trainingWeights.count,
                requiredWeightCount: minimumCalibrationWeightCount,
                balanceDayCount: trainingBalances.count,
                requiredBalanceDayCount: minimumCalibrationBalanceDayCount,
                spanDays: weightSpan,
                requiredSpanDays: minimumCalibrationWeightSpanDays
            )
        }
        guard let line = trendLine(for: trainingWeights, calendar: calendar),
              let firstDate = firstTrainingDate,
              let lastDate = lastTrainingDate else {
            return .unavailable(reason: "Der Gewichtstrend ist noch nicht stabil genug.")
        }

        let trendDays = calendar.dateComponents([.day], from: firstDate, to: lastDate).day ?? 0
        let observedChange = line.slopeKilogramsPerDay * Double(trendDays)
        let predictedChange = trainingBalances.compactMap(\.balanceKilocalories).reduce(0, +) /
            kilocaloriesPerKilogram
        guard abs(predictedChange) >= 0.25 else {
            return .unavailable(
                reason: "Die bisherige Energiebilanz enthält zu wenig Signal für eine persönliche Kalibrierung."
            )
        }
        guard observedChange == 0 || observedChange.sign == predictedChange.sign else {
            return .unavailable(
                reason: "Gewichts- und Bilanztrend zeigen bislang in unterschiedliche Richtungen. Quant passt das Modell deshalb noch nicht an."
            )
        }

        let rawFactor = observedChange / predictedChange
        return .ready(factor: min(max(rawFactor, 0.6), 1.4))
    }

    private static func makeExpectedTrend(
        startDate: Date,
        endDate: Date,
        startingWeight: Double,
        balances: [DailyEnergyBalance],
        factor: Double,
        calendar: Calendar
    ) -> [WeightChartPoint] {
        let balancesByDay = Dictionary(
            balances.compactMap { balance in
                balance.balanceKilocalories.map {
                    (calendar.startOfDay(for: balance.date), $0)
                }
            },
            uniquingKeysWith: { _, newest in newest }
        )
        var points = [WeightChartPoint(date: startDate, kilograms: startingWeight)]
        var weight = startingWeight
        var day = startDate
        while day < endDate {
            if let balance = balancesByDay[day] {
                weight += balance / kilocaloriesPerKilogram * factor
            }
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day),
                  nextDay > day else { break }
            day = nextDay
            points.append(WeightChartPoint(date: min(day, endDate), kilograms: weight))
        }
        return points
    }

    private static func spanDays(
        for weights: [WeightMeasurement],
        calendar: Calendar
    ) -> Int {
        guard let first = weights.first?.date, let last = weights.last?.date else { return 0 }
        return calendar.dateComponents([.day], from: first, to: last).day ?? 0
    }

    private static func trendLine(
        for weights: [WeightMeasurement],
        calendar: Calendar
    ) -> TrendLine? {
        guard weights.count >= 2, let referenceDate = weights.first?.date else { return nil }
        let coordinates = weights.map { measurement in
            (
                x: Double(calendar.dateComponents(
                    [.day],
                    from: referenceDate,
                    to: measurement.date
                ).day ?? 0),
                y: measurement.kilograms
            )
        }
        var slopes: [Double] = []
        for firstIndex in coordinates.indices {
            for secondIndex in coordinates.index(after: firstIndex)..<coordinates.endIndex {
                let deltaX = coordinates[secondIndex].x - coordinates[firstIndex].x
                guard deltaX > 0 else { continue }
                slopes.append((coordinates[secondIndex].y - coordinates[firstIndex].y) / deltaX)
            }
        }
        guard let slope = median(slopes),
              let intercept = median(coordinates.map({ $0.y - slope * $0.x })) else { return nil }
        return TrendLine(
            referenceDate: referenceDate,
            interceptKilograms: intercept,
            slopeKilogramsPerDay: slope
        )
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private struct TrendLine {
        let referenceDate: Date
        let interceptKilograms: Double
        let slopeKilogramsPerDay: Double

        func value(on date: Date, calendar: Calendar) -> Double {
            let days = calendar.dateComponents([.day], from: referenceDate, to: date).day ?? 0
            return interceptKilograms + slopeKilogramsPerDay * Double(days)
        }
    }
}

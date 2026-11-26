import Foundation

enum WeightBalanceComparisonBuilder {
    static let minimumComparisonWeightCount = 4
    static let minimumComparisonWeightSpanDays = 19
    static let minimumCalibrationWeightCount = 12
    static let minimumCalibrationWeightSpanDays = 42
    static let minimumCalibrationBalanceDayCount = 42
    static let calibrationHistoryDayCount = 365
    static let kilocaloriesPerKilogram = 7_700.0
    static let maximumDailyBalanceAdjustmentKilocalories = 500.0

    static func makeComparison(
        measurements: [WeightMeasurement],
        balances: [DailyEnergyBalance],
        comparisonStart: Date,
        now: Date,
        calendar: Calendar,
        calibrationEnabled: Bool
    ) -> WeightBalanceComparison {
        let today = calendar.startOfDay(for: now)
        let requestedComparisonStart = min(
            calendar.startOfDay(for: comparisonStart),
            today
        )
        let selectedSpanDays = max(
            calendar.dateComponents(
                [.day],
                from: requestedComparisonStart,
                to: today
            ).day ?? 0,
            0
        )
        let requiredWeightSpanDays = min(
            minimumComparisonWeightSpanDays,
            selectedSpanDays
        )
        let interval = DateInterval(start: requestedComparisonStart, end: today)
        let dailyWeights = dailyMedians(
            measurements.filter { $0.date >= requestedComparisonStart && $0.date <= now },
            calendar: calendar
        )
        let calibrationStatus = makeCalibrationStatus(
            measurements: measurements,
            balances: balances,
            interval: calibrationInterval(endingAt: now, calendar: calendar),
            calendar: calendar,
            enabled: calibrationEnabled
        )

        let weightSpan = spanDays(for: dailyWeights, calendar: calendar)
        let readiness: WeightComparisonReadiness
        if dailyWeights.count < minimumComparisonWeightCount ||
            weightSpan < requiredWeightSpanDays {
            readiness = .needsWeights(
                current: dailyWeights.count,
                required: minimumComparisonWeightCount,
                spanDays: weightSpan,
                requiredSpanDays: requiredWeightSpanDays
            )
        } else {
            readiness = .ready
        }

        guard let line = trendLine(for: dailyWeights, calendar: calendar) else {
            return WeightBalanceComparison(
                interval: interval,
                dailyWeights: dailyWeights,
                observedTrend: [],
                observedChangeKilograms: nil,
                readiness: readiness,
                calibrationStatus: calibrationStatus
            )
        }

        guard let firstWeightDate = dailyWeights.first?.date,
              let lastWeightDate = dailyWeights.last?.date else {
            return WeightBalanceComparison(
                interval: interval,
                dailyWeights: dailyWeights,
                observedTrend: [],
                observedChangeKilograms: nil,
                readiness: readiness,
                calibrationStatus: calibrationStatus
            )
        }
        let observedStart = line.value(on: firstWeightDate, calendar: calendar)
        let observedEnd = line.value(on: lastWeightDate, calendar: calendar)

        return WeightBalanceComparison(
            interval: interval,
            dailyWeights: dailyWeights,
            observedTrend: [
                WeightChartPoint(date: firstWeightDate, kilograms: observedStart),
                WeightChartPoint(date: lastWeightDate, kilograms: observedEnd),
            ],
            observedChangeKilograms: line.slopeKilogramsPerDay * Double(weightSpan),
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

    static func calibrationInterval(
        endingAt date: Date,
        calendar: Calendar
    ) -> DateInterval {
        let end = calendar.startOfDay(for: date)
        let start = calendar.date(
            byAdding: .day,
            value: -calibrationHistoryDayCount,
            to: end
        ) ?? end
        return DateInterval(start: start, end: end)
    }

    private static func makeCalibrationStatus(
        measurements: [WeightMeasurement],
        balances: [DailyEnergyBalance],
        interval: DateInterval,
        calendar: Calendar,
        enabled: Bool
    ) -> PersonalCalibrationStatus {
        guard enabled else { return .disabled }
        let firstCompleteBalanceDate = balances
            .filter {
                $0.date >= interval.start &&
                    $0.date < interval.end &&
                    $0.completeness == .complete
            }
            .map(\.date)
            .min()
        let trainingWeights = dailyMedians(
            measurements.filter {
                guard let firstCompleteBalanceDate else { return false }
                return $0.date >= firstCompleteBalanceDate &&
                    $0.date >= interval.start &&
                    $0.date < interval.end
            },
            calendar: calendar
        )
        let firstTrainingDate = trainingWeights.first?.date
        let lastTrainingDate = trainingWeights.last?.date
        let trainingBalances = balances.filter { balance in
            guard let firstTrainingDate, let lastTrainingDate else { return false }
            return balance.date >= firstTrainingDate &&
                balance.date < lastTrainingDate &&
                balance.date >= interval.start &&
                balance.date < interval.end &&
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
        let recordedBalances = trainingBalances.compactMap(\.balanceKilocalories)
        let recordedBalanceSum = recordedBalances.reduce(0, +)
        let predictedChange = recordedBalanceSum / kilocaloriesPerKilogram
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

        let recordedDailyBalance = recordedBalanceSum / Double(recordedBalances.count)
        let observedDailyBalance = line.slopeKilogramsPerDay * kilocaloriesPerKilogram
        let rawDailyAdjustment = observedDailyBalance - recordedDailyBalance
        let boundedDailyAdjustment = min(
            max(
                rawDailyAdjustment,
                -maximumDailyBalanceAdjustmentKilocalories
            ),
            maximumDailyBalanceAdjustmentKilocalories
        )
        return .ready(
            dailyBalanceAdjustmentKilocalories: boundedDailyAdjustment,
            uncappedDailyBalanceAdjustmentKilocalories: rawDailyAdjustment
        )
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

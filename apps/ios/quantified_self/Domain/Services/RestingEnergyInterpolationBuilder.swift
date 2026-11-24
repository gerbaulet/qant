import Foundation

enum RestingEnergyInterpolationBuilder {
    static let lookbackDayCount = 28
    static let minimumMeasuredDuration: TimeInterval = 24 * 60 * 60
    static let minimumMeasuredDayCount = 2

    private static let minimumHourlyProfileSampleCount = 2
    private static let durationTolerance: TimeInterval = 0.001

    private struct RateSample {
        let date: Date
        let localHour: Int
        let kilocaloriesPerSecond: Double
        let measuredDuration: TimeInterval
    }

    static func fillGaps(
        in values: [FusedRestingEnergyInterval],
        from startDate: Date,
        to endDate: Date,
        calendar: Calendar
    ) -> [FusedRestingEnergyInterval] {
        guard startDate < endDate else { return [] }
        var result = values.sorted { lhs, rhs in
            if lhs.interval.start == rhs.interval.start {
                return lhs.interval.end < rhs.interval.end
            }
            return lhs.interval.start < rhs.interval.start
        }
        let gapGroups = consecutiveGapGroups(in: result)

        for group in gapGroups {
            let missingDuration = group.reduce(0) {
                $0 + result[$1].coverage.missingDuration
            }
            guard missingDuration < RestingEnergyCoverage.liveFeatureMissingDurationLimit else {
                markExcessiveGap(
                    group,
                    in: &result,
                    from: startDate,
                    to: endDate
                )
                continue
            }
            guard let firstIndex = group.first else { continue }
            let gapStart = result[firstIndex].interval.start
            guard let profile = makeProfile(
                from: result,
                before: gapStart,
                calendar: calendar
            ) else {
                continue
            }

            for index in group where interval(
                result[index].interval,
                intersectsFrom: startDate,
                to: endDate
            ) {
                let value = result[index]
                let duration = value.coverage.missingDuration
                guard duration > durationTolerance else { continue }
                let localHour = calendar.component(.hour, from: value.interval.start)
                let rate = profile.hourlyRates[localHour] ?? profile.overallRate
                let estimate = rate * duration
                result[index] = FusedRestingEnergyInterval(
                    interval: value.interval,
                    kilocalories: (value.kilocalories ?? 0) + estimate,
                    estimatedKilocalories: value.estimatedKilocalories + estimate,
                    coverage: RestingEnergyCoverage(
                        expectedDuration: value.coverage.expectedDuration,
                        primaryDuration: value.coverage.primaryDuration,
                        iPhoneFallbackDuration: value.coverage.iPhoneFallbackDuration,
                        estimatedDuration: value.coverage.estimatedDuration + duration,
                        pendingDuration: value.coverage.pendingDuration,
                        hasExcessiveGap: value.coverage.hasExcessiveGap
                    )
                )
            }
        }

        return result.filter {
            interval($0.interval, intersectsFrom: startDate, to: endDate)
        }
    }

    private static func markExcessiveGap(
        _ group: [Int],
        in values: inout [FusedRestingEnergyInterval],
        from startDate: Date,
        to endDate: Date
    ) {
        for index in group where interval(
            values[index].interval,
            intersectsFrom: startDate,
            to: endDate
        ) {
            let value = values[index]
            values[index] = FusedRestingEnergyInterval(
                interval: value.interval,
                kilocalories: value.kilocalories,
                estimatedKilocalories: value.estimatedKilocalories,
                coverage: RestingEnergyCoverage(
                    expectedDuration: value.coverage.expectedDuration,
                    primaryDuration: value.coverage.primaryDuration,
                    iPhoneFallbackDuration: value.coverage.iPhoneFallbackDuration,
                    estimatedDuration: value.coverage.estimatedDuration,
                    pendingDuration: value.coverage.pendingDuration,
                    hasExcessiveGap: true
                )
            )
        }
    }

    private static func consecutiveGapGroups(
        in values: [FusedRestingEnergyInterval]
    ) -> [[Int]] {
        var groups: [[Int]] = []
        var current: [Int] = []

        for index in values.indices {
            let hasMissingDuration = values[index].coverage.missingDuration >
                durationTolerance
            let followsPrevious = current.last.map {
                abs(values[$0].interval.end.timeIntervalSince(values[index].interval.start)) <=
                    durationTolerance
            } ?? true

            if hasMissingDuration, followsPrevious {
                current.append(index)
            } else {
                if !current.isEmpty {
                    groups.append(current)
                    current = []
                }
                if hasMissingDuration {
                    current = [index]
                }
            }
        }
        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }

    private struct Profile {
        let hourlyRates: [Int: Double]
        let overallRate: Double
    }

    private static func makeProfile(
        from values: [FusedRestingEnergyInterval],
        before date: Date,
        calendar: Calendar
    ) -> Profile? {
        guard let lookbackStart = calendar.date(
            byAdding: .day,
            value: -lookbackDayCount,
            to: date
        ) else {
            return nil
        }
        let samples = values.compactMap { value -> RateSample? in
            guard value.interval.end <= date,
                  value.interval.end > lookbackStart,
                  let totalKilocalories = value.kilocalories else {
                return nil
            }
            let measuredDuration = value.coverage.measuredDuration
            let measuredKilocalories = totalKilocalories - value.estimatedKilocalories
            guard measuredDuration > durationTolerance,
                  measuredKilocalories.isFinite,
                  measuredKilocalories > 0 else {
                return nil
            }
            return RateSample(
                date: value.interval.start,
                localHour: calendar.component(.hour, from: value.interval.start),
                kilocaloriesPerSecond: measuredKilocalories / measuredDuration,
                measuredDuration: measuredDuration
            )
        }
        let measuredDuration = samples.reduce(0) { $0 + $1.measuredDuration }
        let measuredDays = Set(samples.map { calendar.startOfDay(for: $0.date) })
        guard measuredDuration + durationTolerance >= minimumMeasuredDuration,
              measuredDays.count >= minimumMeasuredDayCount,
              let overallRate = median(samples.map(\.kilocaloriesPerSecond)) else {
            return nil
        }
        let hourlyRates = Dictionary(grouping: samples, by: \.localHour)
            .compactMapValues { hourSamples -> Double? in
                guard hourSamples.count >= minimumHourlyProfileSampleCount else {
                    return nil
                }
                return median(hourSamples.map(\.kilocaloriesPerSecond))
            }
        return Profile(hourlyRates: hourlyRates, overallRate: overallRate)
    }

    private static func interval(
        _ interval: DateInterval,
        intersectsFrom startDate: Date,
        to endDate: Date
    ) -> Bool {
        interval.start < endDate && interval.end > startDate
    }

    private static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}

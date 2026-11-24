import Foundation

struct RestingEnergySampleValue: Sendable, Equatable {
    let interval: DateInterval
    let kilocalories: Double
}

struct RestingEnergySampleBucket: Sendable, Equatable {
    let interval: DateInterval
    let kilocalories: Double
    let coveredDuration: TimeInterval
}

enum RestingEnergySampleBucketBuilder {
    private struct Accumulator {
        let interval: DateInterval
        var kilocalories = 0.0
        var coveredIntervals: [DateInterval] = []
    }

    static func makeBuckets(
        from samples: [RestingEnergySampleValue],
        within queryInterval: DateInterval,
        calendar: Calendar
    ) -> [Date: RestingEnergySampleBucket] {
        guard queryInterval.duration > 0 else { return [:] }
        var accumulators: [Date: Accumulator] = [:]

        for sample in samples {
            guard sample.kilocalories.isFinite, sample.kilocalories >= 0 else {
                continue
            }
            if sample.interval.duration <= 1 {
                addPointSample(
                    sample,
                    within: queryInterval,
                    calendar: calendar,
                    to: &accumulators
                )
            } else {
                addIntervalSample(
                    sample,
                    within: queryInterval,
                    calendar: calendar,
                    to: &accumulators
                )
            }
        }

        return accumulators.mapValues { accumulator in
            RestingEnergySampleBucket(
                interval: accumulator.interval,
                kilocalories: accumulator.kilocalories,
                coveredDuration: unionDuration(accumulator.coveredIntervals)
            )
        }
    }

    private static func addPointSample(
        _ sample: RestingEnergySampleValue,
        within queryInterval: DateInterval,
        calendar: Calendar,
        to accumulators: inout [Date: Accumulator]
    ) {
        let date = sample.interval.start
        guard date >= queryInterval.start, date < queryInterval.end,
              let hour = calendar.dateInterval(of: .hour, for: date),
              let coveredInterval = hour.intersection(with: queryInterval) else {
            return
        }
        add(
            kilocalories: sample.kilocalories,
            coveredInterval: coveredInterval,
            hour: hour,
            to: &accumulators
        )
    }

    private static func addIntervalSample(
        _ sample: RestingEnergySampleValue,
        within queryInterval: DateInterval,
        calendar: Calendar,
        to accumulators: inout [Date: Accumulator]
    ) {
        guard let clipped = sample.interval.intersection(with: queryInterval),
              clipped.duration > 0 else {
            return
        }

        var cursor = clipped.start
        while cursor < clipped.end {
            guard let hour = calendar.dateInterval(of: .hour, for: cursor),
                  let overlap = hour.intersection(with: clipped),
                  overlap.duration > 0 else {
                break
            }
            add(
                kilocalories: sample.kilocalories * overlap.duration / sample.interval.duration,
                coveredInterval: overlap,
                hour: hour,
                to: &accumulators
            )
            cursor = overlap.end
        }
    }

    private static func add(
        kilocalories: Double,
        coveredInterval: DateInterval,
        hour: DateInterval,
        to accumulators: inout [Date: Accumulator]
    ) {
        var accumulator = accumulators[hour.start] ?? Accumulator(interval: hour)
        accumulator.kilocalories += kilocalories
        accumulator.coveredIntervals.append(coveredInterval)
        accumulators[hour.start] = accumulator
    }

    private static func unionDuration(_ intervals: [DateInterval]) -> TimeInterval {
        let sorted = intervals.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        guard var current = sorted.first else { return 0 }
        var duration = 0.0

        for interval in sorted.dropFirst() {
            if interval.start <= current.end {
                current = DateInterval(
                    start: current.start,
                    end: max(current.end, interval.end)
                )
            } else {
                duration += current.duration
                current = interval
            }
        }
        return duration + current.duration
    }
}

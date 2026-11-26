import Foundation

enum HealthMetricsQueryPlanner {
    static func calibrationInterval(
        endingAt date: Date,
        enabled: Bool,
        hasRequestedWeightAccess: Bool,
        calendar: Calendar
    ) -> DateInterval? {
        guard enabled, hasRequestedWeightAccess else { return nil }
        return WeightBalanceComparisonBuilder.calibrationInterval(
            endingAt: date,
            calendar: calendar
        )
    }

    static func covering(_ intervals: [DateInterval?]) -> DateInterval? {
        let presentIntervals = intervals.compactMap { $0 }
        guard let first = presentIntervals.first else { return nil }
        return presentIntervals.dropFirst().reduce(first) { result, interval in
            DateInterval(
                start: min(result.start, interval.start),
                end: max(result.end, interval.end)
            )
        }
    }
}

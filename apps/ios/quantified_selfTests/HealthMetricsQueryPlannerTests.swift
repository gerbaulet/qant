import Foundation
import Testing
@testable import Quant

struct HealthMetricsQueryPlannerTests {
    @Test("Calibration history requires enabled weight access")
    func calibrationHistoryRequiresWeightAccess() {
        let calendar = utcCalendar()
        let now = date(2026, 11, 26, calendar: calendar)

        #expect(HealthMetricsQueryPlanner.calibrationInterval(
            endingAt: now,
            enabled: true,
            hasRequestedWeightAccess: false,
            calendar: calendar
        ) == nil)
        #expect(HealthMetricsQueryPlanner.calibrationInterval(
            endingAt: now,
            enabled: false,
            hasRequestedWeightAccess: true,
            calendar: calendar
        ) == nil)

        let interval = HealthMetricsQueryPlanner.calibrationInterval(
            endingAt: now,
            enabled: true,
            hasRequestedWeightAccess: true,
            calendar: calendar
        )
        #expect(interval?.start == date(2025, 11, 26, calendar: calendar))
        #expect(interval?.end == now)
    }

    @Test("Covering interval includes every requested feature window")
    func coveringIntervalIncludesEveryWindow() {
        let calendar = utcCalendar()
        let oldest = DateInterval(
            start: date(2025, 11, 26, calendar: calendar),
            end: date(2026, 11, 26, calendar: calendar)
        )
        let current = DateInterval(
            start: date(2026, 8, 28, calendar: calendar),
            end: date(2026, 11, 27, calendar: calendar)
        )

        let interval = HealthMetricsQueryPlanner.covering([current, nil, oldest])

        #expect(interval?.start == oldest.start)
        #expect(interval?.end == current.end)
    }

    @Test("Covering interval ignores absent optional features")
    func coveringIntervalIgnoresAbsentFeatures() {
        let calendar = utcCalendar()
        let forecast = DateInterval(
            start: date(2026, 8, 28, calendar: calendar),
            end: date(2026, 11, 27, calendar: calendar)
        )

        #expect(HealthMetricsQueryPlanner.covering([forecast, nil]) == forecast)
        #expect(HealthMetricsQueryPlanner.covering([nil, nil]) == nil)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}

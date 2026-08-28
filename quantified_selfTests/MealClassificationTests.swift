import Foundation
import Testing
@testable import Quant

struct MealClassificationTests {
    @Test("Default category boundaries are half-open")
    func defaultBoundaries() {
        let schedule = MealClassificationSchedule.default
        let calendar = calendar(timeZone: "Europe/Berlin")

        #expect(schedule.category(for: date(4, 59, calendar: calendar), calendar: calendar) == .snack)
        #expect(schedule.category(for: date(5, 0, calendar: calendar), calendar: calendar) == .breakfast)
        #expect(schedule.category(for: date(10, 59, calendar: calendar), calendar: calendar) == .breakfast)
        #expect(schedule.category(for: date(11, 0, calendar: calendar), calendar: calendar) == .lunch)
        #expect(schedule.category(for: date(14, 59, calendar: calendar), calendar: calendar) == .lunch)
        #expect(schedule.category(for: date(15, 0, calendar: calendar), calendar: calendar) == .snack)
        #expect(schedule.category(for: date(17, 0, calendar: calendar), calendar: calendar) == .dinner)
        #expect(schedule.category(for: date(21, 59, calendar: calendar), calendar: calendar) == .dinner)
        #expect(schedule.category(for: date(22, 0, calendar: calendar), calendar: calendar) == .snack)
    }

    @Test("Classification uses the supplied time zone")
    func timeZoneChangesLocalClassification() {
        let schedule = MealClassificationSchedule.default
        let instant = ISO8601DateFormatter().date(from: "2026-08-23T08:00:00Z")!
        let berlin = calendar(timeZone: "Europe/Berlin")
        let losAngeles = calendar(timeZone: "America/Los_Angeles")

        #expect(schedule.category(for: instant, calendar: berlin) == .breakfast)
        #expect(schedule.category(for: instant, calendar: losAngeles) == .snack)
    }

    @Test("Configurable windows may cross midnight")
    func windowCrossingMidnight() {
        let window = MealTimeWindow(
            startMinutesSinceMidnight: 22 * 60,
            endMinutesSinceMidnight: 2 * 60
        )

        #expect(window.contains(minutesSinceMidnight: 23 * 60))
        #expect(window.contains(minutesSinceMidnight: 60))
        #expect(!window.contains(minutesSinceMidnight: 12 * 60))
    }

    private func calendar(timeZone identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private func date(_ hour: Int, _ minute: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 23,
            hour: hour,
            minute: minute
        ))!
    }
}

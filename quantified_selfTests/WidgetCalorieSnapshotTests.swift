import Foundation
import Testing
@testable import Quant

struct WidgetCalorieSnapshotTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "de_DE")
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    @Test("The widget text uses the requested German date and rounded calories")
    func confirmedText() {
        let date = makeDate(2026, 9, 10, 12)
        let snapshot = WidgetCalorieSnapshot(
            dayStart: calendar.startOfDay(for: date),
            energyKilocalories: 2_123.4,
            hasProvisionalValues: false
        )

        #expect(WidgetCalorieTextFormatter.text(
            for: date,
            snapshot: snapshot,
            calendar: calendar,
            numberLocale: Locale(identifier: "de_DE")
        ) == "Do. 10. · 2.123 kcal")
    }

    @Test("Provisional calories receive a tilde")
    func provisionalText() {
        let date = makeDate(2026, 9, 10, 12)
        let snapshot = WidgetCalorieSnapshot(
            dayStart: calendar.startOfDay(for: date),
            energyKilocalories: 2_122.6,
            hasProvisionalValues: true
        )

        #expect(WidgetCalorieTextFormatter.text(
            for: date,
            snapshot: snapshot,
            calendar: calendar,
            numberLocale: Locale(identifier: "de_DE")
        ) == "Do. 10. · ~2.123 kcal")
    }

    @Test("A stale snapshot becomes zero on the new local day")
    func staleSnapshot() {
        let previousDate = makeDate(2026, 9, 10, 12)
        let currentDate = makeDate(2026, 9, 11, 0)
        let snapshot = WidgetCalorieSnapshot(
            dayStart: calendar.startOfDay(for: previousDate),
            energyKilocalories: 2_123,
            hasProvisionalValues: true
        )

        #expect(WidgetCalorieTextFormatter.text(
            for: currentDate,
            snapshot: snapshot,
            calendar: calendar,
            numberLocale: Locale(identifier: "de_DE")
        ) == "Fr. 11. · 0 kcal")
    }

    @Test("The calorie number follows the device locale")
    func localizedNumber() {
        let date = makeDate(2026, 9, 10, 12)
        let snapshot = WidgetCalorieSnapshot(
            dayStart: calendar.startOfDay(for: date),
            energyKilocalories: 2_123,
            hasProvisionalValues: false
        )

        #expect(WidgetCalorieTextFormatter.text(
            for: date,
            snapshot: snapshot,
            calendar: calendar,
            numberLocale: Locale(identifier: "en_US")
        ) == "Do. 10. · 2,123 kcal")
    }

    @Test("The shared store only reports changed payloads")
    func persistenceChangeDetection() throws {
        let suiteName = "WidgetCalorieSnapshotTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = WidgetCalorieSnapshotStore(defaults: defaults)
        let date = makeDate(2026, 9, 10, 12)
        let snapshot = WidgetCalorieSnapshot(
            dayStart: calendar.startOfDay(for: date),
            energyKilocalories: 800,
            hasProvisionalValues: false
        )

        #expect(store.save(snapshot))
        #expect(!store.save(snapshot))
        #expect(store.snapshot(for: date, calendar: calendar) == snapshot)
    }

    private func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour
        ))!
    }
}

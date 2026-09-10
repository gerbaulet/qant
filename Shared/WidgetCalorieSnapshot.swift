import Foundation

struct WidgetCalorieSnapshot: Codable, Equatable, Hashable, Sendable {
    let dayStart: Date
    let energyKilocalories: Double
    let hasProvisionalValues: Bool

    static func empty(for date: Date, calendar: Calendar) -> WidgetCalorieSnapshot {
        WidgetCalorieSnapshot(
            dayStart: calendar.startOfDay(for: date),
            energyKilocalories: 0,
            hasProvisionalValues: false
        )
    }

    func applies(to date: Date, calendar: Calendar) -> Bool {
        calendar.isDate(dayStart, inSameDayAs: date)
    }
}

enum QuantWidgetConfiguration {
    static let appGroupIdentifier = "group.de.clemensgerbaulet.quantified-self"
    static let snapshotKey = "widget.calorieSnapshot"
    static let widgetKind = "QuantInlineCalories"
    static let todayURL = URL(string: "quant://today")!
}

struct WidgetCalorieSnapshotStore {
    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = UserDefaults(
        suiteName: QuantWidgetConfiguration.appGroupIdentifier
    )) {
        self.defaults = defaults
    }

    @discardableResult
    func save(_ snapshot: WidgetCalorieSnapshot) -> Bool {
        guard let defaults,
              let data = try? JSONEncoder().encode(snapshot) else {
            return false
        }
        let existingSnapshot = defaults.data(forKey: QuantWidgetConfiguration.snapshotKey)
            .flatMap { try? JSONDecoder().decode(WidgetCalorieSnapshot.self, from: $0) }
        guard existingSnapshot != snapshot else {
            return false
        }
        defaults.set(data, forKey: QuantWidgetConfiguration.snapshotKey)
        return true
    }

    func snapshot(for date: Date, calendar: Calendar) -> WidgetCalorieSnapshot {
        guard let data = defaults?.data(forKey: QuantWidgetConfiguration.snapshotKey),
              let snapshot = try? JSONDecoder().decode(WidgetCalorieSnapshot.self, from: data),
              snapshot.applies(to: date, calendar: calendar) else {
            return .empty(for: date, calendar: calendar)
        }
        return snapshot
    }
}

enum WidgetCalorieTextFormatter {
    static func text(
        for date: Date,
        snapshot: WidgetCalorieSnapshot,
        calendar: Calendar,
        numberLocale: Locale = .autoupdatingCurrent
    ) -> String {
        let currentSnapshot = snapshot.applies(to: date, calendar: calendar)
            ? snapshot
            : .empty(for: date, calendar: calendar)
        let prefix = currentSnapshot.hasProvisionalValues ? "~" : ""
        let energy = currentSnapshot.energyKilocalories.formatted(
            .number
                .precision(.fractionLength(0))
                .locale(numberLocale)
        )
        return "\(prefix)\(energy) kcal"
    }

    static func accessibilityText(
        for date: Date,
        snapshot: WidgetCalorieSnapshot,
        calendar: Calendar,
        numberLocale: Locale = .autoupdatingCurrent
    ) -> String {
        let currentSnapshot = snapshot.applies(to: date, calendar: calendar)
            ? snapshot
            : .empty(for: date, calendar: calendar)
        let energy = currentSnapshot.energyKilocalories.formatted(
            .number
                .precision(.fractionLength(0))
                .locale(numberLocale)
        )
        let provisional = currentSnapshot.hasProvisionalValues ? ", vorläufig" : ""
        return "\(energy) Kilokalorien\(provisional)"
    }
}

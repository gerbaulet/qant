import Foundation

struct MealTimeWindow: Equatable, Sendable {
    let startMinutesSinceMidnight: Int
    let endMinutesSinceMidnight: Int

    init(startMinutesSinceMidnight: Int, endMinutesSinceMidnight: Int) {
        precondition((0..<1_440).contains(startMinutesSinceMidnight))
        precondition((0...1_440).contains(endMinutesSinceMidnight))
        precondition(startMinutesSinceMidnight != endMinutesSinceMidnight)
        self.startMinutesSinceMidnight = startMinutesSinceMidnight
        self.endMinutesSinceMidnight = endMinutesSinceMidnight
    }

    func contains(minutesSinceMidnight: Int) -> Bool {
        if startMinutesSinceMidnight < endMinutesSinceMidnight {
            return minutesSinceMidnight >= startMinutesSinceMidnight &&
                minutesSinceMidnight < endMinutesSinceMidnight
        }

        // A window such as 22:00–02:00 crosses local midnight.
        return minutesSinceMidnight >= startMinutesSinceMidnight ||
            minutesSinceMidnight < endMinutesSinceMidnight
    }
}

struct MealClassificationSchedule: Equatable, Sendable {
    let breakfast: MealTimeWindow
    let lunch: MealTimeWindow
    let dinner: MealTimeWindow

    static let `default` = MealClassificationSchedule(
        breakfast: MealTimeWindow(
            startMinutesSinceMidnight: 5 * 60,
            endMinutesSinceMidnight: 11 * 60
        ),
        lunch: MealTimeWindow(
            startMinutesSinceMidnight: 11 * 60,
            endMinutesSinceMidnight: 15 * 60
        ),
        dinner: MealTimeWindow(
            startMinutesSinceMidnight: 17 * 60,
            endMinutesSinceMidnight: 22 * 60
        )
    )

    func category(for date: Date, calendar: Calendar) -> MealCategory {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else {
            return .snack
        }

        let minutesSinceMidnight = hour * 60 + minute
        if breakfast.contains(minutesSinceMidnight: minutesSinceMidnight) {
            return .breakfast
        }
        if lunch.contains(minutesSinceMidnight: minutesSinceMidnight) {
            return .lunch
        }
        if dinner.contains(minutesSinceMidnight: minutesSinceMidnight) {
            return .dinner
        }
        return .snack
    }
}

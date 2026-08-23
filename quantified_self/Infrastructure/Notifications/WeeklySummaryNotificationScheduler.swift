import Foundation
import UserNotifications

struct WeeklySummaryNotificationSchedule: Equatable, Sendable {
    static let identifier = "weekly-nutrition-summary"

    static var sundayEvening: DateComponents {
        DateComponents(calendar: .autoupdatingCurrent, timeZone: .autoupdatingCurrent, hour: 20, minute: 0, weekday: 1)
    }
}

@MainActor
final class WeeklySummaryNotificationScheduler {
    enum EnableResult: Equatable {
        case enabled
        case denied
        case failed
    }

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func enable() async -> EnableResult {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            guard granted else { return .denied }

            let content = UNMutableNotificationContent()
            content.title = "Deine Wochenübersicht ist bereit"
            content.body = "Öffne die App für deine lokal berechnete Ernährungsübersicht."
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: WeeklySummaryNotificationSchedule.identifier,
                content: content,
                trigger: UNCalendarNotificationTrigger(
                    dateMatching: WeeklySummaryNotificationSchedule.sundayEvening,
                    repeats: true
                )
            )
            center.removePendingNotificationRequests(withIdentifiers: [WeeklySummaryNotificationSchedule.identifier])
            try await center.add(request)
            return .enabled
        } catch {
            return .failed
        }
    }

    func disable() {
        center.removePendingNotificationRequests(withIdentifiers: [WeeklySummaryNotificationSchedule.identifier])
    }
}

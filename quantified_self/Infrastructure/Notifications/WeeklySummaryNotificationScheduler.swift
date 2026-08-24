import Foundation
import OSLog
import UserNotifications

struct WeeklySummaryNotificationSchedule: Equatable, Sendable {
    static let identifier = "weekly-nutrition-summary"
    static let testIdentifier = "weekly-nutrition-summary-test"
    static let testDelay: TimeInterval = 5

    static var sundayEvening: DateComponents {
        // Temporary test cadence: omitting the weekday makes the unchanged
        // Sunday reminder repeat every evening.
        DateComponents(calendar: .autoupdatingCurrent, timeZone: .autoupdatingCurrent, hour: 20, minute: 0)
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
            guard try await requestAuthorization() else { return .denied }

            let content = makeContent()

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
            AppLogger.notifications.info("Weekly summary reminder scheduled")
            return .enabled
        } catch {
            AppLogger.notifications.error("Weekly summary reminder scheduling failed")
            return .failed
        }
    }

    func scheduleTestNotification() async -> EnableResult {
        do {
            guard try await requestAuthorization() else { return .denied }

            let request = UNNotificationRequest(
                identifier: WeeklySummaryNotificationSchedule.testIdentifier,
                content: makeContent(),
                trigger: UNTimeIntervalNotificationTrigger(
                    timeInterval: WeeklySummaryNotificationSchedule.testDelay,
                    repeats: false
                )
            )
            center.removePendingNotificationRequests(withIdentifiers: [WeeklySummaryNotificationSchedule.testIdentifier])
            try await center.add(request)
            AppLogger.notifications.info("Weekly summary test reminder scheduled")
            return .enabled
        } catch {
            AppLogger.notifications.error("Weekly summary test reminder scheduling failed")
            return .failed
        }
    }

    func disable() {
        center.removePendingNotificationRequests(withIdentifiers: [WeeklySummaryNotificationSchedule.identifier])
        AppLogger.notifications.info("Weekly summary reminder removed")
    }

    private func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    private func makeContent() -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Deine Wochenübersicht ist bereit"
        content.body = "Öffne die App für deine lokal berechnete Ernährungsübersicht und passende Tipps für nächste Woche."
        content.sound = .default
        return content
    }
}

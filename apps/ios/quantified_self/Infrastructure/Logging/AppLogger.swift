import Foundation
import OSLog

enum AppLogger {
    nonisolated private static let subsystem = Bundle.main.bundleIdentifier ?? "quantified-self"

    nonisolated static let persistence = Logger(subsystem: subsystem, category: "persistence")
    nonisolated static let imageStorage = Logger(subsystem: subsystem, category: "imageStorage")
    nonisolated static let capture = Logger(subsystem: subsystem, category: "capture")
    nonisolated static let nutritionAnalysis = Logger(subsystem: subsystem, category: "nutritionAnalysis")
    nonisolated static let statistics = Logger(subsystem: subsystem, category: "statistics")
    nonisolated static let notifications = Logger(subsystem: subsystem, category: "notifications")
}

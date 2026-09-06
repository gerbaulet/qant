import Foundation
import UIKit

@MainActor
final class SystemBackgroundExecutionManager: BackgroundExecutionManaging {
    static let shared = SystemBackgroundExecutionManager()

    private var tasks: [UUID: UIBackgroundTaskIdentifier] = [:]

    private init() {}

    func begin(name: String, expirationHandler: @escaping @Sendable () -> Void) -> UUID? {
        let token = UUID()
        let task = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            expirationHandler()
            Task { @MainActor [weak self] in
                self?.end(token)
            }
        }
        guard task != .invalid else { return nil }
        tasks[token] = task
        return token
    }

    func end(_ identifier: UUID) {
        guard let task = tasks.removeValue(forKey: identifier) else { return }
        UIApplication.shared.endBackgroundTask(task)
    }
}

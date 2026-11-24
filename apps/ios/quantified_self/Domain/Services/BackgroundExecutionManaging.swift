import Foundation

@MainActor
protocol BackgroundExecutionManaging {
    func begin(name: String, expirationHandler: @escaping @Sendable () -> Void) -> UUID?
    func end(_ identifier: UUID)
}

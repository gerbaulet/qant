import Foundation

protocol RetryDelaySleeping: Sendable {
    func sleep(beforeAttempt attempt: Int) async throws
}

struct SystemRetryDelaySleeper: RetryDelaySleeping {
    func sleep(beforeAttempt attempt: Int) async throws {
        let exponent = min(max(attempt - 2, 0), 6)
        let seconds = min(pow(2, Double(exponent)), 60)
        try await Task.sleep(for: .seconds(seconds))
    }
}

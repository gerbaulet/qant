import Foundation
import Network

protocol NetworkAvailabilityWaiting {
    func waitUntilAvailable() async throws
}

struct SystemNetworkAvailabilityWaiter: NetworkAvailabilityWaiting {
    func waitUntilAvailable() async throws {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "de.clemensgerbaulet.qant.network-availability")
        let availability = AsyncStream<Void> { continuation in
            monitor.pathUpdateHandler = { path in
                guard path.status == .satisfied else { return }
                continuation.yield()
                continuation.finish()
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: queue)
        }

        for await _ in availability {
            try Task.checkCancellation()
            return
        }
        try Task.checkCancellation()
    }
}

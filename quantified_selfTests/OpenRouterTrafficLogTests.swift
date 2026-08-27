import Foundation
import Testing
@testable import quantified_self

@Suite(.serialized)
struct OpenRouterTrafficLogTests {
    @Test("Enabled traffic logging persists timestamped requests and responses without image data")
    func persistsSanitizedTraffic() async throws {
        let fixture = try makeFixture(enabled: true)
        defer { fixture.cleanup() }
        let requestID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let imageData = String(repeating: "A", count: 1_024)
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "example/model",
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": "Bitte analysieren"],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(imageData)"]],
                ],
            ]],
        ])

        await fixture.log.recordRequest(
            id: requestID,
            method: "POST",
            url: URL(string: "https://openrouter.example/chat/completions")!,
            headers: ["Accept": "application/json", "Content-Type": "application/json"],
            body: body
        )
        await fixture.log.recordResponse(
            id: requestID,
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"choices":[{"message":{"content":"Antworttext"}}]}"#.utf8)
        )

        let contents = await fixture.log.contents()
        #expect(contents.contains("[2026-08-27T10:11:12.345Z] REQUEST [\(requestID.uuidString)]"))
        #expect(contents.contains("POST https://openrouter.example/chat/completions"))
        #expect(contents.contains("Bitte analysieren"))
        #expect(contents.contains("Nichttext gekürzt: data:image/jpeg;base64,"))
        #expect(!contents.contains(imageData))
        #expect(contents.contains("[2026-08-27T10:11:12.345Z] RESPONSE [\(requestID.uuidString)]"))
        #expect(contents.contains("HTTP 200"))
        #expect(contents.contains("Antworttext"))
    }

    @Test("Disabled traffic logging does not create entries")
    func disabledLogging() async throws {
        let fixture = try makeFixture(enabled: false)
        defer { fixture.cleanup() }

        await fixture.log.recordRequest(
            id: UUID(),
            method: "GET",
            url: URL(string: "https://openrouter.example/models")!,
            headers: [:],
            body: nil
        )

        #expect(await fixture.log.contents().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }

    @Test("Clearing removes all persisted log contents")
    func clearingLog() async throws {
        let fixture = try makeFixture(enabled: true)
        defer { fixture.cleanup() }
        await fixture.log.recordFailure(id: UUID(), description: "Testfehler")
        #expect(!(await fixture.log.contents()).isEmpty)

        try await fixture.log.clear()

        #expect(await fixture.log.contents().isEmpty)
    }

    private func makeFixture(enabled: Bool) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "openrouter-traffic-log-tests-\(UUID().uuidString)")
        let suiteName = "openrouter-traffic-log-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(enabled, forKey: OpenRouterTrafficLogSettings.enabledKey)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fixedDate = try #require(formatter.date(from: "2026-08-27T10:11:12.345Z"))
        let fileURL = directory.appending(path: "OpenRouterTraffic.log")
        return Fixture(
            log: FileOpenRouterTrafficLog(
                fileURL: fileURL,
                defaults: defaults,
                now: { fixedDate }
            ),
            fileURL: fileURL,
            directory: directory,
            defaults: defaults,
            suiteName: suiteName
        )
    }

    private struct Fixture {
        let log: FileOpenRouterTrafficLog
        let fileURL: URL
        let directory: URL
        let defaults: UserDefaults
        let suiteName: String

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

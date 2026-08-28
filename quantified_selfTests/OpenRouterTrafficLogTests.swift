import Foundation
import Testing
@testable import Quant

@Suite(.serialized)
struct OpenRouterTrafficLogTests {
    @Test("Large log text previews are bounded and report omitted characters")
    func boundsLargeTextPreview() {
        let text = String(repeating: "Modell", count: 10_000)

        let preview = OpenRouterTrafficLogTextPreview(text: text, characterLimit: 1_000)

        #expect(preview.text.count == 1_000)
        #expect(preview.omittedCharacterCount == text.count - 1_000)
        #expect(text.count == 60_000)
    }

    @Test("Short log text previews remain unchanged")
    func preservesShortTextPreview() {
        let text = #"{"data":[]}"#

        let preview = OpenRouterTrafficLogTextPreview(text: text, characterLimit: 1_000)

        #expect(preview.text == text)
        #expect(preview.omittedCharacterCount == 0)
    }

    @Test("Logging persists one structured entry with sanitized request and response text")
    func persistsStructuredSanitizedTraffic() async throws {
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
            headers: [
                "Authorization": "Bearer secret",
                "Content-Type": "application/json",
            ],
            body: body
        )
        await fixture.log.recordResponse(
            id: requestID,
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"choices":[{"message":{"content":"Antworttext"}}]}"#.utf8)
        )

        let entry = try #require(await fixture.log.entries().first)
        #expect(entry.id == requestID)
        #expect(entry.requestedAt == fixture.fixedDate)
        #expect(entry.respondedAt == fixture.fixedDate)
        #expect(entry.method == "POST")
        #expect(entry.url == "https://openrouter.example/chat/completions")
        #expect(entry.requestHeaders["Authorization"] == nil)
        #expect(entry.requestText.contains("Bitte analysieren"))
        #expect(entry.requestText.contains("Nichttext entfernt: image/jpeg"))
        #expect(!entry.requestText.contains(imageData))
        #expect(entry.statusCode == 200)
        #expect(entry.responseText?.contains("Antworttext") == true)
    }

    @Test("Disabled traffic logging does not create model entries")
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

        #expect(try await fixture.log.entries().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }

    @Test("Responses and failures are correlated with their requests")
    func correlatesResults() async throws {
        let fixture = try makeFixture(enabled: true)
        defer { fixture.cleanup() }
        let failedID = UUID()
        let successfulID = UUID()

        await fixture.log.recordRequest(
            id: failedID,
            method: "POST",
            url: URL(string: "https://openrouter.example/failed")!,
            headers: [:],
            body: nil
        )
        await fixture.log.recordFailure(id: failedID, description: "Zeitüberschreitung")
        await fixture.log.recordRequest(
            id: successfulID,
            method: "GET",
            url: URL(string: "https://openrouter.example/success")!,
            headers: [:],
            body: nil
        )
        await fixture.log.recordResponse(
            id: successfulID,
            statusCode: 204,
            headers: [:],
            body: Data()
        )

        let entries = try await fixture.log.entries()
        #expect(entries.count == 2)
        #expect(entries.first(where: { $0.id == failedID })?.failureDescription == "Zeitüberschreitung")
        #expect(entries.first(where: { $0.id == successfulID })?.statusCode == 204)
    }

    @Test("Structured entries survive creating a new log store")
    func restoresPersistedEntries() async throws {
        let fixture = try makeFixture(enabled: true)
        defer { fixture.cleanup() }
        let requestID = UUID()
        await fixture.log.recordRequest(
            id: requestID,
            method: "POST",
            url: URL(string: "https://openrouter.example/chat")!,
            headers: ["Content-Type": "text/plain"],
            body: Data("Hallo".utf8)
        )

        let restoredLog = FileOpenRouterTrafficLog(
            fileURL: fixture.fileURL,
            defaults: fixture.defaults,
            now: { fixture.fixedDate }
        )

        let restored = try await restoredLog.entries()
        #expect(restored.count == 1)
        #expect(restored.first?.id == requestID)
        #expect(restored.first?.requestText == "Hallo")
    }

    @Test("Clearing removes structured and legacy logs")
    func clearingLog() async throws {
        let fixture = try makeFixture(enabled: true)
        defer { fixture.cleanup() }
        let requestID = UUID()
        await fixture.log.recordRequest(
            id: requestID,
            method: "GET",
            url: URL(string: "https://openrouter.example/models")!,
            headers: [:],
            body: nil
        )
        let legacyURL = fixture.directory.appending(path: "OpenRouterTraffic.log")
        try Data("Altbestand".utf8).write(to: legacyURL)

        try await fixture.log.clear()

        #expect(try await fixture.log.entries().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    }

    private func makeFixture(enabled: Bool) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "openrouter-traffic-log-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = "openrouter-traffic-log-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(enabled, forKey: OpenRouterTrafficLogSettings.enabledKey)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fixedDate = try #require(formatter.date(from: "2026-08-27T10:11:12.345Z"))
        let fileURL = directory.appending(path: "OpenRouterTraffic.json")
        return Fixture(
            log: FileOpenRouterTrafficLog(fileURL: fileURL, defaults: defaults, now: { fixedDate }),
            fileURL: fileURL,
            directory: directory,
            defaults: defaults,
            suiteName: suiteName,
            fixedDate: fixedDate
        )
    }

    private struct Fixture: @unchecked Sendable {
        let log: FileOpenRouterTrafficLog
        let fileURL: URL
        let directory: URL
        let defaults: UserDefaults
        let suiteName: String
        let fixedDate: Date

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

import Foundation
import OSLog

enum OpenRouterTrafficLogSettings {
    nonisolated static let enabledKey = "openrouter.traffic-log-enabled"
}

struct OpenRouterTrafficLogSnapshot: Sendable, Equatable {
    let contents: String
    let isTruncated: Bool
}

protocol OpenRouterTrafficLogging: Sendable {
    func recordRequest(
        id: UUID,
        method: String,
        url: URL,
        headers: [String: String],
        body: Data?
    ) async
    func recordResponse(
        id: UUID,
        statusCode: Int,
        headers: [String: String],
        body: Data
    ) async
    func recordFailure(id: UUID, description: String) async
}

actor FileOpenRouterTrafficLog: OpenRouterTrafficLogging {
    static let shared = FileOpenRouterTrafficLog()

    nonisolated private let fileURL: URL
    nonisolated(unsafe) private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    nonisolated(unsafe) private let fileManager: FileManager

    init(
        fileURL: URL? = nil,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "OpenRouterTraffic.log")
        self.defaults = defaults
        self.now = now
    }

    func recordRequest(
        id: UUID,
        method: String,
        url: URL,
        headers: [String: String],
        body: Data?
    ) {
        guard isEnabled else { return }
        append(
            """
            [\(timestamp)] REQUEST [\(id.uuidString)]
            \(method) \(url.absoluteString)
            Headers: \(formattedHeaders(headers))
            Body:
            \(formattedBody(body, contentType: headers["Content-Type"]))
            """
        )
    }

    func recordResponse(
        id: UUID,
        statusCode: Int,
        headers: [String: String],
        body: Data
    ) {
        guard isEnabled else { return }
        append(
            """
            [\(timestamp)] RESPONSE [\(id.uuidString)]
            HTTP \(statusCode)
            Headers: \(formattedHeaders(headers))
            Body:
            \(formattedBody(body, contentType: contentType(in: headers)))
            """
        )
    }

    func recordFailure(id: UUID, description: String) {
        guard isEnabled else { return }
        append(
            """
            [\(timestamp)] FAILURE [\(id.uuidString)]
            \(description)
            """
        )
    }

    func contents() -> String {
        guard let data = try? Data(contentsOf: fileURL) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated func snapshot(maximumBytes: Int) async throws -> OpenRouterTrafficLogSnapshot {
        let fileURL = fileURL
        return try await Task.detached(priority: .userInitiated) {
            guard maximumBytes > 0 else {
                return OpenRouterTrafficLogSnapshot(contents: "", isTruncated: false)
            }
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return OpenRouterTrafficLogSnapshot(contents: "", isTruncated: false)
            }

            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            let maximumByteCount = UInt64(maximumBytes)
            let isTruncated = size > maximumByteCount
            if isTruncated {
                try handle.seek(toOffset: size - maximumByteCount)
            } else {
                try handle.seek(toOffset: 0)
            }
            let data = try handle.readToEnd() ?? Data()
            return OpenRouterTrafficLogSnapshot(
                contents: String(decoding: data, as: UTF8.self),
                isTruncated: isTruncated
            )
        }.value
    }

    func clear() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try Data().write(to: fileURL, options: .atomic)
    }

    private var isEnabled: Bool {
        defaults.bool(forKey: OpenRouterTrafficLogSettings.enabledKey)
    }

    private var timestamp: String {
        now().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .colon))
    }

    private func append(_ entry: String) {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = Data((entry + "\n\n").utf8)
            if !fileManager.fileExists(atPath: fileURL.path) {
                try data.write(to: fileURL, options: .atomic)
                return
            }

            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            AppLogger.nutritionAnalysis.error("OpenRouter traffic log could not be persisted")
        }
    }

    private func formattedHeaders(_ headers: [String: String]) -> String {
        guard !headers.isEmpty else { return "{}" }
        return headers
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
    }

    private func contentType(in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
    }

    private func formattedBody(_ body: Data?, contentType: String?) -> String {
        guard let body, !body.isEmpty else { return "(kein Body)" }
        let normalizedContentType = contentType?.lowercased() ?? ""
        guard normalizedContentType.isEmpty ||
                normalizedContentType.contains("json") ||
                normalizedContentType.hasPrefix("text/") else {
            return "<Nichttext gekürzt: \(contentType ?? "unbekannter Typ"), \(body.count) Bytes>"
        }

        if let json = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]),
           let sanitizedData = try? JSONSerialization.data(
               withJSONObject: sanitizedJSON(json),
               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
           ) {
            return String(decoding: sanitizedData, as: UTF8.self)
        }

        guard let text = String(data: body, encoding: .utf8) else {
            return "<Nichttext gekürzt: \(body.count) Bytes>"
        }
        return text
    }

    private func sanitizedJSON(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.mapValues(sanitizedJSON)
        case let array as [Any]:
            return array.map(sanitizedJSON)
        case let string as String:
            return sanitizedString(string)
        default:
            return value
        }
    }

    private func sanitizedString(_ string: String) -> String {
        if string.lowercased().hasPrefix("data:"), let separator = string.firstIndex(of: ",") {
            let prefix = String(string[...separator])
            return "<Nichttext gekürzt: \(prefix)…; \(string.utf8.count) Zeichen>"
        }
        if string.count > 512, looksLikeBase64(string) {
            return "<Nichttext gekürzt: Base64; \(string.utf8.count) Zeichen>"
        }
        return string
    }

    private func looksLikeBase64(_ string: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/=\r\n"))
        return string.unicodeScalars.allSatisfy(allowed.contains)
    }
}

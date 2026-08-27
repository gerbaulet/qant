import Foundation
import OSLog

enum OpenRouterTrafficLogSettings {
    nonisolated static let enabledKey = "openrouter.traffic-log-enabled"
}

nonisolated struct OpenRouterTrafficLogEntry: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let requestedAt: Date
    let method: String
    let url: String
    let requestHeaders: [String: String]
    let requestText: String
    var respondedAt: Date?
    var statusCode: Int?
    var responseHeaders: [String: String]
    var responseText: String?
    var failureDescription: String?
}

protocol OpenRouterTrafficLogging: Sendable {
    func recordRequest(id: UUID, method: String, url: URL, headers: [String: String], body: Data?) async
    func recordResponse(id: UUID, statusCode: Int, headers: [String: String], body: Data) async
    func recordFailure(id: UUID, description: String) async
}

actor FileOpenRouterTrafficLog: OpenRouterTrafficLogging {
    static let shared = FileOpenRouterTrafficLog()

    nonisolated private let fileURL: URL
    nonisolated private let legacyFileURL: URL
    nonisolated(unsafe) private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    nonisolated(unsafe) private let fileManager: FileManager
    private var cachedEntries: [OpenRouterTrafficLogEntry]?

    init(
        fileURL: URL? = nil,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let resolvedFileURL = fileURL ?? applicationSupport.appending(path: "OpenRouterTraffic.json")
        self.fileURL = resolvedFileURL
        legacyFileURL = resolvedFileURL.deletingLastPathComponent().appending(path: "OpenRouterTraffic.log")
        self.defaults = defaults
        self.fileManager = fileManager
        self.now = now
    }

    func recordRequest(id: UUID, method: String, url: URL, headers: [String: String], body: Data?) {
        guard isEnabled else { return }
        do {
            var entries = try storedEntries()
            entries.removeAll { $0.id == id }
            entries.append(OpenRouterTrafficLogEntry(
                id: id,
                requestedAt: now(),
                method: method,
                url: url.absoluteString,
                requestHeaders: safeHeaders(headers),
                requestText: formattedBody(body, contentType: contentType(in: headers)),
                respondedAt: nil,
                statusCode: nil,
                responseHeaders: [:],
                responseText: nil,
                failureDescription: nil
            ))
            try persist(entries)
        } catch {
            AppLogger.nutritionAnalysis.error("OpenRouter request log could not be persisted")
        }
    }

    func recordResponse(id: UUID, statusCode: Int, headers: [String: String], body: Data) {
        guard isEnabled else { return }
        do {
            var entries = try storedEntries()
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].respondedAt = now()
            entries[index].statusCode = statusCode
            entries[index].responseHeaders = safeHeaders(headers)
            entries[index].responseText = formattedBody(body, contentType: contentType(in: headers))
            entries[index].failureDescription = nil
            try persist(entries)
        } catch {
            AppLogger.nutritionAnalysis.error("OpenRouter response log could not be persisted")
        }
    }

    func recordFailure(id: UUID, description: String) {
        guard isEnabled else { return }
        do {
            var entries = try storedEntries()
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].respondedAt = now()
            entries[index].failureDescription = description
            try persist(entries)
        } catch {
            AppLogger.nutritionAnalysis.error("OpenRouter failure log could not be persisted")
        }
    }

    nonisolated func entries() async throws -> [OpenRouterTrafficLogEntry] {
        let fileURL = fileURL
        return try await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            return try Self.decodeEntries(from: data).sorted { $0.requestedAt > $1.requestedAt }
        }.value
    }

    func clear() throws {
        cachedEntries = []
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        if legacyFileURL != fileURL, fileManager.fileExists(atPath: legacyFileURL.path) {
            try fileManager.removeItem(at: legacyFileURL)
        }
    }

    private var isEnabled: Bool {
        defaults.bool(forKey: OpenRouterTrafficLogSettings.enabledKey)
    }

    private func storedEntries() throws -> [OpenRouterTrafficLogEntry] {
        if let cachedEntries { return cachedEntries }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            cachedEntries = []
            return []
        }
        let entries = try Self.decodeEntries(from: Data(contentsOf: fileURL))
        cachedEntries = entries
        return entries
    }

    private func persist(_ entries: [OpenRouterTrafficLogEntry]) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: fileURL, options: .atomic)
        cachedEntries = entries
    }

    nonisolated private static func decodeEntries(from data: Data) throws -> [OpenRouterTrafficLogEntry] {
        try JSONDecoder().decode([OpenRouterTrafficLogEntry].self, from: data)
    }

    private func safeHeaders(_ headers: [String: String]) -> [String: String] {
        headers.filter { key, _ in key.caseInsensitiveCompare("Authorization") != .orderedSame }
    }

    private func contentType(in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
    }

    private func formattedBody(_ body: Data?, contentType: String?) -> String {
        guard let body, !body.isEmpty else { return "(kein Body)" }
        let normalizedContentType = contentType?.lowercased() ?? ""
        guard normalizedContentType.isEmpty || normalizedContentType.contains("json") || normalizedContentType.hasPrefix("text/") else {
            return "<Nichttext entfernt: \(contentType ?? "unbekannter Typ"), \(body.count) Bytes>"
        }
        if let json = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]),
           let sanitizedData = try? JSONSerialization.data(
               withJSONObject: sanitizedJSON(json),
               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
           ) {
            return String(decoding: sanitizedData, as: UTF8.self)
        }
        guard let text = String(data: body, encoding: .utf8) else {
            return "<Nichttext entfernt: \(body.count) Bytes>"
        }
        return text
    }

    private func sanitizedJSON(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]: return dictionary.mapValues(sanitizedJSON)
        case let array as [Any]: return array.map(sanitizedJSON)
        case let string as String: return sanitizedString(string)
        default: return value
        }
    }

    private func sanitizedString(_ string: String) -> String {
        if string.lowercased().hasPrefix("data:"), let separator = string.firstIndex(of: ",") {
            let mediaType = string[string.index(string.startIndex, offsetBy: 5)..<separator]
                .split(separator: ";", maxSplits: 1).first.map(String.init) ?? "unbekannter Typ"
            return "<Nichttext entfernt: \(mediaType), \(string.utf8.count) Zeichen>"
        }
        if string.count > 512, looksLikeBase64(string) {
            return "<Nichttext entfernt: Base64, \(string.utf8.count) Zeichen>"
        }
        return string
    }

    private func looksLikeBase64(_ string: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/=\r\n"))
        return string.unicodeScalars.allSatisfy(allowed.contains)
    }
}

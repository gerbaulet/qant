import Foundation

protocol OpenRouterSettingsStoring: AnyObject {
    var serverURL: String { get set }
    var modelIdentifier: String { get set }
    var costTier: OpenRouterCostTier { get set }
    var providerPreference: OpenRouterProviderPreference { get set }
    var modelCatalogCache: OpenRouterModelCatalogCache? { get set }
}

enum QuantServerEndpoint {
    static func parse(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            var components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(),
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.path.isEmpty || components.path == "/"
        else {
            throw OpenRouterClientError.invalidServerURL
        }

        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLoopback) else {
            throw OpenRouterClientError.invalidServerURL
        }
        components.scheme = scheme
        components.path = ""
        guard let url = components.url else {
            throw OpenRouterClientError.invalidServerURL
        }
        return url
    }
}

enum OpenRouterProviderPreference: String, CaseIterable, Codable, Equatable, Identifiable {
    case balanced
    case lowLatency = "faster"

    var id: Self { self }

    var title: String {
        switch self {
        case .balanced: "Ausgewogen (Standard)"
        case .lowLatency: "Niedrige Latenz"
        }
    }
}

enum OpenRouterCostTier: String, CaseIterable, Codable, Equatable, Identifiable {
    case low
    case medium
    case high
    case xhigh
    case max

    var id: Self { self }

    var title: String {
        switch self {
        case .low: "Niedrig"
        case .medium: "Mittel"
        case .high: "Hoch"
        case .xhigh: "Sehr hoch"
        case .max: "Maximal"
        }
    }
}

extension String {
    nonisolated var isOpenRouterAutoRouterIdentifier: Bool {
        self == "openrouter/auto" || self == "openrouter/auto-beta"
    }
}

struct OpenRouterModelCatalogCache: Codable, Equatable {
    let options: [OpenRouterModelOption]
    let fetchedAt: Date
}

final class UserDefaultsOpenRouterSettingsStore: OpenRouterSettingsStoring {
    private enum Key {
        static let serverURL = "openrouter.server-url"
        static let modelIdentifier = "openrouter.model-identifier"
        static let costTier = "openrouter.cost-tier"
        static let providerPreference = "openrouter.provider-preference"
        static let modelCatalogCache = "openrouter.model-catalog-cache"
    }

    var serverURL: String {
        get { defaults.string(forKey: Key.serverURL) ?? "" }
        set { defaults.set(newValue, forKey: Key.serverURL) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var modelIdentifier: String {
        get { defaults.string(forKey: Key.modelIdentifier) ?? "" }
        set { defaults.set(newValue, forKey: Key.modelIdentifier) }
    }

    var costTier: OpenRouterCostTier {
        get {
            guard let rawValue = defaults.string(forKey: Key.costTier) else { return .low }
            return OpenRouterCostTier(rawValue: rawValue) ?? .low
        }
        set { defaults.set(newValue.rawValue, forKey: Key.costTier) }
    }

    var providerPreference: OpenRouterProviderPreference {
        get {
            guard let rawValue = defaults.string(forKey: Key.providerPreference) else { return .balanced }
            return OpenRouterProviderPreference(rawValue: rawValue) ?? .balanced
        }
        set { defaults.set(newValue.rawValue, forKey: Key.providerPreference) }
    }

    var modelCatalogCache: OpenRouterModelCatalogCache? {
        get {
            guard let data = defaults.data(forKey: Key.modelCatalogCache) else { return nil }
            return try? JSONDecoder().decode(OpenRouterModelCatalogCache.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: Key.modelCatalogCache)
                return
            }
            defaults.set(data, forKey: Key.modelCatalogCache)
        }
    }
}

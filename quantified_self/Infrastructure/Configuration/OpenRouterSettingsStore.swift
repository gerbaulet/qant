import Foundation

protocol OpenRouterSettingsStoring: AnyObject {
    var modelIdentifier: String { get set }
    var costTier: OpenRouterCostTier { get set }
    var modelCatalogCache: OpenRouterModelCatalogCache? { get set }
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
    var isOpenRouterAutoRouterIdentifier: Bool {
        self == "openrouter/auto" || self == "openrouter/auto-beta"
    }
}

struct OpenRouterModelCatalogCache: Codable, Equatable {
    let options: [OpenRouterModelOption]
    let fetchedAt: Date
}

final class UserDefaultsOpenRouterSettingsStore: OpenRouterSettingsStoring {
    private enum Key {
        static let modelIdentifier = "openrouter.model-identifier"
        static let costTier = "openrouter.cost-tier"
        static let modelCatalogCache = "openrouter.model-catalog-cache"
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

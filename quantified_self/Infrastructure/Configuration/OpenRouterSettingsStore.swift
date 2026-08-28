import Foundation

protocol OpenRouterSettingsStoring: AnyObject {
    var modelIdentifier: String { get set }
    var modelCatalogCache: OpenRouterModelCatalogCache? { get set }
}

struct OpenRouterModelCatalogCache: Codable, Equatable {
    let options: [OpenRouterModelOption]
    let fetchedAt: Date
}

final class UserDefaultsOpenRouterSettingsStore: OpenRouterSettingsStoring {
    private enum Key {
        static let modelIdentifier = "openrouter.model-identifier"
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

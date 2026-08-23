import Foundation

protocol OpenRouterSettingsStoring: AnyObject {
    var modelIdentifier: String { get set }
}

final class UserDefaultsOpenRouterSettingsStore: OpenRouterSettingsStoring {
    private enum Key {
        static let modelIdentifier = "openrouter.model-identifier"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var modelIdentifier: String {
        get { defaults.string(forKey: Key.modelIdentifier) ?? "" }
        set { defaults.set(newValue, forKey: Key.modelIdentifier) }
    }
}

import Foundation
import TiholeCore

/// Persists the non-secret app configuration (instances, active instance,
/// theme) as JSON in UserDefaults. Passwords are stored separately in the
/// Keychain.
enum ConfigStore {
    private static let key = "tihole.config.v1"

    static func load(from defaults: UserDefaults = .standard) -> AppConfig {
        guard let data = defaults.data(forKey: key),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data)
        else {
            return AppConfig()
        }
        return config
    }

    static func save(_ config: AppConfig, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(config) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    /// Forgets every instance and its Keychain password. UI tests use this to
    /// start from a clean first-run state.
    static func reset(defaults: UserDefaults = .standard) {
        for instance in load(from: defaults).instances {
            Keychain.deletePassword(for: instance.id)
        }
        defaults.removeObject(forKey: key)
    }
}

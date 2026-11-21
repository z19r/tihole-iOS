import Foundation

/// A single configured Pi-hole instance.
///
/// The password is deliberately not part of this type: it lives in the
/// Keychain, keyed by `id`, so the saved config never contains a secret.
public struct InstanceConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var url: String
    /// False opts into accepting a self-signed certificate from this host.
    public var verifyTLS: Bool

    public init(
        id: UUID = UUID(), name: String, url: String, verifyTLS: Bool = true
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.verifyTLS = verifyTLS
    }
}

/// The app's saved configuration: the iOS counterpart of tihole's
/// `config.yaml`.
public struct AppConfig: Codable, Equatable, Sendable {
    /// The active instance's id, or nil before any instance exists.
    public var activeID: UUID?
    /// Theme name (see the app's theme list); empty means the default.
    public var theme: String
    public var instances: [InstanceConfig]

    public init(
        activeID: UUID? = nil, theme: String = "",
        instances: [InstanceConfig] = []
    ) {
        self.activeID = activeID
        self.theme = theme
        self.instances = instances
    }

    /// The active instance, falling back to the first one when `activeID`
    /// does not match (for example after the active instance was deleted).
    public var activeInstance: InstanceConfig? {
        if let activeID,
            let match = instances.first(where: { $0.id == activeID })
        {
            return match
        }
        return instances.first
    }

    /// Structural problems with the config, as human-readable messages. An
    /// empty result means the config is valid.
    public func validationErrors() -> [String] {
        var errors: [String] = []

        if instances.isEmpty {
            errors.append("no instances configured")
        }

        var seen = Set<String>()
        for (index, instance) in instances.enumerated() {
            let name = instance.name.trimmingCharacters(
                in: .whitespacesAndNewlines)
            if name.isEmpty {
                errors.append("instance \(index + 1): name is required")
            } else if seen.contains(name) {
                errors.append("instance \"\(name)\": duplicate name")
            } else {
                seen.insert(name)
            }

            if let problem = InstanceConfig.urlProblem(instance.url) {
                let label = name.isEmpty ? "#\(index + 1)" : name
                errors.append("instance \"\(label)\": \(problem)")
            }
        }

        if !instances.isEmpty {
            if let activeID {
                if !instances.contains(where: { $0.id == activeID }) {
                    errors.append("active instance does not match any instance")
                }
            } else {
                errors.append("active instance is required")
            }
        }

        return errors
    }
}

extension InstanceConfig {
    /// Why `raw` is not a usable instance URL, or nil when it is fine. The
    /// URL must be http or https and name a host.
    public static func urlProblem(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "url is required"
        }
        guard let components = URLComponents(string: trimmed) else {
            return "invalid url"
        }
        let scheme = (components.scheme ?? "").lowercased()
        if scheme != "http" && scheme != "https" {
            return "url must start with http:// or https://"
        }
        if (components.host ?? "").isEmpty {
            return "url has no host"
        }
        return nil
    }

    /// Adds "https://" to a bare host ("pi.hole", "10.0.0.53") so people can
    /// type what they would type into a browser. https is the default so the
    /// password never crosses the network in clear text by accident.
    public static func normalizedURL(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return value
        }
        if !value.lowercased().hasPrefix("http://")
            && !value.lowercased().hasPrefix("https://")
        {
            value = "https://" + value
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}

extension AppConfig {
    /// The config with instance `id` updated, or with a new instance added
    /// when `id` is nil or unknown. If no instance is active, the saved one
    /// becomes active. Also returns the saved instance's id.
    public func upserting(
        id: UUID?,
        name: String,
        url: String,
        verifyTLS: Bool
    ) -> (config: AppConfig, id: UUID) {
        var next = self
        let savedID: UUID
        if let id, let index = next.instances.firstIndex(where: { $0.id == id })
        {
            next.instances[index].name = name
            next.instances[index].url = url
            next.instances[index].verifyTLS = verifyTLS
            savedID = id
        } else {
            let instance = InstanceConfig(
                name: name, url: url, verifyTLS: verifyTLS)
            next.instances.append(instance)
            savedID = instance.id
        }
        if !next.instances.contains(where: { $0.id == next.activeID }) {
            next.activeID = savedID
        }
        return (next, savedID)
    }

    /// The config without instance `id`. If the active instance is gone, the
    /// first remaining one becomes active.
    public func removing(_ id: UUID) -> AppConfig {
        var next = self
        next.instances.removeAll { $0.id == id }
        if !next.instances.contains(where: { $0.id == next.activeID }) {
            next.activeID = next.instances.first?.id
        }
        return next
    }
}

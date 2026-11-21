import Foundation
import PiholeKit

/// One editable setting in the FTL config tree, addressed by a dotted path
/// such as "dns.upstreams".
public struct ConfigLeaf: Identifiable, Equatable, Sendable {
    public var path: String
    public var value: JSONValue
    public var description: String
    /// FTL's own type label ("boolean", "enum (string)", ...), when the tree
    /// was fetched with `detailed: true`.
    public var dataType: String
    public var defaultValue: JSONValue?
    /// Allowed values for enum-typed settings.
    public var allowed: [JSONValue]
    /// True when the value differs from FTL's default.
    public var modified: Bool

    public var id: String { path }

    public init(
        path: String,
        value: JSONValue,
        description: String = "",
        dataType: String = "",
        defaultValue: JSONValue? = nil,
        allowed: [JSONValue] = [],
        modified: Bool = false
    ) {
        self.path = path
        self.value = value
        self.description = description
        self.dataType = dataType
        self.defaultValue = defaultValue
        self.allowed = allowed
        self.modified = modified
    }

    /// The first path segment ("dns" for "dns.upstreams"), used to section
    /// the settings list.
    public var section: String {
        path.split(separator: ".").first.map(String.init) ?? path
    }

    /// The path without its section prefix.
    public var name: String {
        let parts = path.split(separator: ".")
        if parts.count <= 1 {
            return path
        }
        return parts.dropFirst().joined(separator: ".")
    }
}

/// How a leaf can be edited in the UI.
public enum ConfigEditKind: Equatable, Sendable {
    case toggle
    case number
    case text
    /// One of a fixed set of values.
    case choice([String])
    /// A list of strings, edited row by row.
    case stringList
    /// Objects, nulls, and mixed arrays: shown but not editable.
    case readOnly
}

public enum ConfigTree {
    // MARK: - Flattening

    /// Flattens the config tree into a path-sorted list of leaves. Works for
    /// both the plain tree and the `detailed` tree, where each leaf is an
    /// object carrying `value` plus metadata.
    public static func flatten(_ tree: JSONValue) -> [ConfigLeaf] {
        var out: [ConfigLeaf] = []
        if let object = tree.objectValue {
            walk(prefix: "", object: object, into: &out)
        }
        out.sort { $0.path < $1.path }
        return out
    }

    private static func walk(
        prefix: String, object: [String: JSONValue],
        into out: inout [ConfigLeaf]
    ) {
        for (key, value) in object {
            let path = prefix.isEmpty ? key : prefix + "." + key
            if let child = value.objectValue {
                if isDetailLeaf(child) {
                    out.append(detailLeaf(path: path, object: child))
                } else {
                    walk(prefix: path, object: child, into: &out)
                }
                continue
            }
            out.append(ConfigLeaf(path: path, value: value))
        }
    }

    /// A detailed leaf has a `value` key plus at least one metadata key.
    static func isDetailLeaf(_ object: [String: JSONValue]) -> Bool {
        guard object["value"] != nil else {
            return false
        }
        for key in ["type", "description", "default", "flags", "modified"]
        where object[key] != nil {
            return true
        }
        return false
    }

    private static func detailLeaf(path: String, object: [String: JSONValue])
        -> ConfigLeaf
    {
        ConfigLeaf(
            path: path,
            value: object["value"] ?? .null,
            description: object["description"]?.stringValue ?? "",
            dataType: object["type"]?.stringValue ?? "",
            defaultValue: object["default"],
            allowed: object["allowed"]?.arrayValue ?? [],
            modified: object["modified"]?.boolValue ?? false
        )
    }

    /// Leaves whose path contains `query`, case-insensitively. A blank query
    /// returns everything.
    public static func filter(_ leaves: [ConfigLeaf], query: String)
        -> [ConfigLeaf]
    {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if needle.isEmpty {
            return leaves
        }
        return leaves.filter { $0.path.lowercased().contains(needle) }
    }

    // MARK: - Display

    /// A one-line rendering of any config value.
    public static func stringify(_ value: JSONValue?) -> String {
        guard let value else {
            return "null"
        }
        switch value {
        case .null:
            return "null"
        case .bool(let flag):
            return flag ? "true" : "false"
        case .string(let text):
            return text
        case .number(let number):
            if let whole = Int64(exactly: number) {
                return String(whole)
            }
            return String(number)
        case .array(let items):
            return "[" + items.map { stringify($0) }.joined(separator: ", ")
                + "]"
        case .object:
            return "{…}"
        }
    }

    /// The type shown in the detail view: FTL's own label when present,
    /// otherwise one derived from the value.
    public static func typeLabel(_ leaf: ConfigLeaf) -> String {
        let declared = leaf.dataType.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if !declared.isEmpty {
            return declared
        }
        switch leaf.value {
        case .bool: return "boolean"
        case .number: return "number"
        case .string: return "text"
        case .array: return "list"
        case .null, .object: return "value"
        }
    }

    /// The allowed values as display strings. FTL lists them either as bare
    /// values or as `{ "item": ..., "description": ... }` objects.
    public static func allowedInputs(_ leaf: ConfigLeaf) -> [String] {
        leaf.allowed.compactMap { entry in
            if let object = entry.objectValue {
                guard let item = object["item"] else {
                    return nil
                }
                return stringify(item)
            }
            return stringify(entry)
        }
    }

    // MARK: - Editing

    public static func editKind(_ leaf: ConfigLeaf) -> ConfigEditKind {
        switch leaf.value {
        case .bool:
            return .toggle
        case .number:
            return .number
        case .string:
            let options = allowedInputs(leaf)
            return options.isEmpty ? .text : .choice(options)
        case .array(let items):
            let allStrings = items.allSatisfy { $0.stringValue != nil }
            return allStrings ? .stringList : .readOnly
        case .null, .object:
            return .readOnly
        }
    }

    public struct ParseError: Error, Equatable, LocalizedError {
        public var input: String
        public var expected: String

        public var errorDescription: String? {
            "\"\(input)\" is not a valid \(expected)"
        }
    }

    /// Coerces edited text back to the type of the original value so a
    /// boolean stays a boolean and a number stays a number in the PATCH.
    public static func parse(original: JSONValue, input: String) throws
        -> JSONValue
    {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        switch original {
        case .bool:
            switch text.lowercased() {
            case "true", "t", "1", "yes", "on": return .bool(true)
            case "false", "f", "0", "no", "off": return .bool(false)
            default: throw ParseError(input: text, expected: "boolean")
            }
        case .number:
            guard let number = Double(text), number.isFinite else {
                throw ParseError(input: text, expected: "number")
            }
            return .number(number)
        default:
            return .string(text)
        }
    }

    /// Builds the nested PATCH body for a dotted path: "dns.blocking.active" ->
    /// `{ "dns": { "blocking": { "active": value } } }`.
    public static func patch(path: String, value: JSONValue) -> JSONValue {
        let parts = path.split(separator: ".").map(String.init)
        var node = value
        for part in parts.reversed() {
            node = .object([part: node])
        }
        return node
    }
}

public enum InfoRows {
    public struct Row: Identifiable, Equatable, Sendable {
        public var key: String
        public var value: String
        public var id: String { key }

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    /// Flattens an `/info/*` section into key-sorted rows. Nested objects
    /// become dotted keys; arrays of scalars are joined; anything else is
    /// skipped.
    public static func flatten(_ value: JSONValue) -> [Row] {
        var out: [Row] = []
        collect(prefix: "", value: value, into: &out)
        out.sort { $0.key < $1.key }
        return out
    }

    private static func collect(
        prefix: String, value: JSONValue, into out: inout [Row]
    ) {
        switch value {
        case .object(let object):
            for (key, child) in object {
                let path = prefix.isEmpty ? key : prefix + "." + key
                collect(prefix: path, value: child, into: &out)
            }
        case .array(let items):
            let scalars = items.filter { $0.isScalar }
            if !prefix.isEmpty && !scalars.isEmpty
                && scalars.count == items.count
            {
                out.append(
                    Row(
                        key: prefix,
                        value: scalars.map { ConfigTree.stringify($0) }.joined(
                            separator: ", "))
                )
            }
        case .string, .bool, .number:
            if !prefix.isEmpty {
                out.append(Row(key: prefix, value: ConfigTree.stringify(value)))
            }
        case .null:
            break
        }
    }
}

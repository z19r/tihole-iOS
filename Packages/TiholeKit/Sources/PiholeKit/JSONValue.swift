import Foundation

/// An open-ended JSON value.
///
/// Pi-hole's config tree and `/info/*` endpoints return objects whose shape
/// varies by FTL version, so they are modeled as a tree rather than as fixed
/// structs (the Go client uses `map[string]any` for the same reason).
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "unsupported JSON value"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            // Whole numbers go out as integers so FTL's integer-typed config
            // keys accept them (85, not 85.0).
            if let whole = Int64(exactly: value) {
                try container.encode(whole)
            } else {
                try container.encode(value)
            }
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

extension JSONValue {
    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// True for strings, booleans, and numbers (not null, arrays, or objects).
    public var isScalar: Bool {
        switch self {
        case .string, .bool, .number: return true
        case .null, .array, .object: return false
        }
    }

    /// Looks up a key when this value is an object.
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Walks a dotted path ("dns.hosts") through nested objects.
    public func value(atPath path: String) -> JSONValue? {
        var node: JSONValue = self
        for segment in path.split(separator: ".") {
            guard let next = node[String(segment)] else { return nil }
            node = next
        }
        return node
    }
}

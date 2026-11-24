import PiholeKit

/// One Pi-hole's machine stats, which cannot be combined across Pi-holes.
public struct MemberHealth: Sendable, Equatable {
    public var system: SystemInfo
    public var sensors: Sensors
    /// Diagnostics messages, or nil when they could not be read.
    public var messages: Int?

    public init(
        system: SystemInfo = SystemInfo(), sensors: Sensors = Sensors(),
        messages: Int? = nil
    ) {
        self.system = system
        self.sensors = sensors
        self.messages = messages
    }
}

/// One row of the combined dashboard's per-instance strip.
public struct InstanceRow: Equatable, Identifiable {
    public var name: String
    public var isActive: Bool
    /// Nil until the Pi-hole is first probed, or when it is unreachable.
    public var health: MemberHealth?
    public var isUnreachable: Bool
    /// Domains on its gravity list, when its summary answered.
    public var gravity: Int?

    public var id: String { name }
}

public enum InstanceRows {
    /// Rows shown before the rest collapse into "and N more…".
    public static let limit = 4

    /// Rows in config order with the active instance first. A Pi-hole with
    /// no probe result yet is unknown, not unreachable.
    public static func build(
        order: [String],
        active: String?,
        health: [String: Result<MemberHealth, Error>],
        gravity: [String: Int]
    ) -> [InstanceRow] {
        let names =
            order.filter { $0 == active } + order.filter { $0 != active }
        return names.map { name in
            var row = InstanceRow(
                name: name, isActive: name == active, health: nil,
                isUnreachable: false, gravity: gravity[name])
            switch health[name] {
            case .success(let value): row.health = value
            case .failure: row.isUnreachable = true
            case nil: break
            }
            return row
        }
    }

    /// The gravity most reachable rows report. Ties go to the earliest row,
    /// which is the active instance when it answered.
    public static func commonGravity(_ rows: [InstanceRow]) -> Int? {
        let values = rows.filter { !$0.isUnreachable }.compactMap(\.gravity)
        var counts: [Int: Int] = [:]
        for value in values {
            counts[value, default: 0] += 1
        }
        // max(by:) keeps the first of equal elements.
        return values.max { counts[$0]! < counts[$1]! }
    }
}

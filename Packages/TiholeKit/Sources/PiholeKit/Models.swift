import Foundation

// FTL omits keys and sends nulls freely (a domain with no comment arrives as
// `"comment": null`), so every model decodes leniently: a missing, null, or
// mistyped field falls back to a zero value instead of failing the whole
// response. This matches how the Go client's encoding/json behaves.

extension KeyedDecodingContainer {
    /// Decodes `key`, falling back to `fallback` when it is absent, null, or
    /// of the wrong type.
    func lenient<T: Decodable>(_ key: Key, default fallback: T) -> T {
        if let value = try? decodeIfPresent(T.self, forKey: key) {
            return value
        }
        return fallback
    }

    /// Decodes `key` as an optional, yielding nil when absent, null, or of the
    /// wrong type.
    func optional<T: Decodable>(_ key: Key, as type: T.Type = T.self) -> T? {
        if let value = try? decodeIfPresent(T.self, forKey: key) {
            return value
        }
        return nil
    }
}

// MARK: - Auth

/// The object inside the `session` key of an `/api/auth` response.
public struct PiholeSession: Decodable, Sendable, Equatable {
    public var valid = false
    public var sid = ""
    public var csrf = ""
    public var validity = 0
    public var message = ""
    public var totp = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case valid, sid, csrf, validity, message, totp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        valid = c.lenient(.valid, default: false)
        sid = c.lenient(.sid, default: "")
        csrf = c.lenient(.csrf, default: "")
        validity = c.lenient(.validity, default: 0)
        message = c.lenient(.message, default: "")
        totp = c.lenient(.totp, default: false)
    }
}

struct SessionEnvelope: Decodable {
    var session = PiholeSession()

    enum CodingKeys: String, CodingKey {
        case session
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session = c.lenient(.session, default: PiholeSession())
    }
}

// MARK: - Stats

/// Response of `GET /api/stats/summary`.
public struct Summary: Decodable, Sendable, Equatable {
    public struct Queries: Decodable, Sendable, Equatable {
        public var total = 0
        public var blocked = 0
        public var percentBlocked = 0.0
        public var uniqueDomains = 0
        public var forwarded = 0
        public var cached = 0
        public var frequency = 0.0

        public init() {}

        enum CodingKeys: String, CodingKey {
            case total, blocked, forwarded, cached, frequency
            case percentBlocked = "percent_blocked"
            case uniqueDomains = "unique_domains"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            total = c.lenient(.total, default: 0)
            blocked = c.lenient(.blocked, default: 0)
            percentBlocked = c.lenient(.percentBlocked, default: 0.0)
            uniqueDomains = c.lenient(.uniqueDomains, default: 0)
            forwarded = c.lenient(.forwarded, default: 0)
            cached = c.lenient(.cached, default: 0)
            frequency = c.lenient(.frequency, default: 0.0)
        }
    }

    public struct Clients: Decodable, Sendable, Equatable {
        public var active = 0
        public var total = 0

        public init() {}

        enum CodingKeys: String, CodingKey {
            case active, total
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            active = c.lenient(.active, default: 0)
            total = c.lenient(.total, default: 0)
        }
    }

    public struct Gravity: Decodable, Sendable, Equatable {
        public var domainsBeingBlocked = 0
        public var lastUpdate = 0

        public init() {}

        enum CodingKeys: String, CodingKey {
            case domainsBeingBlocked = "domains_being_blocked"
            case lastUpdate = "last_update"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            domainsBeingBlocked = c.lenient(.domainsBeingBlocked, default: 0)
            lastUpdate = c.lenient(.lastUpdate, default: 0)
        }
    }

    public var queries = Queries()
    public var clients = Clients()
    public var gravity = Gravity()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case queries, clients, gravity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        queries = c.lenient(.queries, default: Queries())
        clients = c.lenient(.clients, default: Clients())
        gravity = c.lenient(.gravity, default: Gravity())
    }
}

/// A single upstream entry in an `/api/stats/upstreams` response.
public struct UpstreamServer: Decodable, Sendable, Equatable {
    public var ip = ""
    public var name = ""
    public var port = 0
    public var count = 0
    public var responseTime = 0.0
    public var variance = 0.0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case ip, name, port, count, statistics
    }

    enum StatisticsKeys: String, CodingKey {
        case response, variance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ip = c.lenient(.ip, default: "")
        name = c.lenient(.name, default: "")
        port = c.lenient(.port, default: 0)
        count = c.lenient(.count, default: 0)
        if let stats = try? c.nestedContainer(keyedBy: StatisticsKeys.self, forKey: .statistics) {
            responseTime = stats.lenient(.response, default: 0.0)
            variance = stats.lenient(.variance, default: 0.0)
        }
    }
}

/// Response of `GET /api/stats/upstreams`.
public struct Upstreams: Decodable, Sendable, Equatable {
    public var upstreams: [UpstreamServer] = []
    public var forwardedQueries = 0
    public var totalQueries = 0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case upstreams
        case forwardedQueries = "forwarded_queries"
        case totalQueries = "total_queries"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        upstreams = c.lenient(.upstreams, default: [])
        forwardedQueries = c.lenient(.forwardedQueries, default: 0)
        totalQueries = c.lenient(.totalQueries, default: 0)
    }
}

/// Response of `GET /api/stats/query_types`, keyed by type name ("A", "AAAA").
public struct QueryTypes: Decodable, Sendable, Equatable {
    public var types: [String: Int] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey {
        case types
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        types = c.lenient(.types, default: [:])
    }
}

/// Response of `GET /api/stats/top_domains`.
public struct TopDomains: Decodable, Sendable, Equatable {
    public struct Entry: Decodable, Sendable, Equatable {
        public var domain = ""
        public var count = 0

        public init() {}

        enum CodingKeys: String, CodingKey {
            case domain, count
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            domain = c.lenient(.domain, default: "")
            count = c.lenient(.count, default: 0)
        }
    }

    public var domains: [Entry] = []
    public var totalQueries = 0
    public var blockedQueries = 0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case domains
        case totalQueries = "total_queries"
        case blockedQueries = "blocked_queries"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        domains = c.lenient(.domains, default: [])
        totalQueries = c.lenient(.totalQueries, default: 0)
        blockedQueries = c.lenient(.blockedQueries, default: 0)
    }
}

/// Response of `GET /api/stats/top_clients`.
public struct TopClients: Decodable, Sendable, Equatable {
    public struct Entry: Decodable, Sendable, Equatable {
        public var ip = ""
        public var name = ""
        public var count = 0

        public init() {}

        enum CodingKeys: String, CodingKey {
            case ip, name, count
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ip = c.lenient(.ip, default: "")
            name = c.lenient(.name, default: "")
            count = c.lenient(.count, default: 0)
        }
    }

    public var clients: [Entry] = []
    public var totalQueries = 0
    public var blockedQueries = 0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case clients
        case totalQueries = "total_queries"
        case blockedQueries = "blocked_queries"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clients = c.lenient(.clients, default: [])
        totalQueries = c.lenient(.totalQueries, default: 0)
        blockedQueries = c.lenient(.blockedQueries, default: 0)
    }
}

// MARK: - History

/// A single timestamped bucket in an `/api/history` response.
public struct HistoryPoint: Decodable, Sendable, Equatable {
    public var timestamp = 0
    public var total = 0
    public var cached = 0
    public var blocked = 0
    public var forwarded = 0

    public init() {}

    public init(timestamp: Int, total: Int, cached: Int = 0, blocked: Int = 0, forwarded: Int = 0) {
        self.timestamp = timestamp
        self.total = total
        self.cached = cached
        self.blocked = blocked
        self.forwarded = forwarded
    }

    enum CodingKeys: String, CodingKey {
        case timestamp, total, cached, blocked, forwarded
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = c.lenient(.timestamp, default: 0)
        total = c.lenient(.total, default: 0)
        cached = c.lenient(.cached, default: 0)
        blocked = c.lenient(.blocked, default: 0)
        forwarded = c.lenient(.forwarded, default: 0)
    }
}

/// Response of `GET /api/history`.
public struct QueryHistory: Decodable, Sendable, Equatable {
    public var history: [HistoryPoint] = []

    public init() {}

    enum CodingKeys: String, CodingKey {
        case history
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        history = c.lenient(.history, default: [])
    }
}

// MARK: - Queries

/// A single row in an `/api/queries` response.
public struct DNSQuery: Decodable, Sendable, Equatable, Identifiable {
    public struct Client: Decodable, Sendable, Equatable {
        public var ip = ""
        public var name = ""

        public init() {}

        public init(ip: String, name: String) {
            self.ip = ip
            self.name = name
        }

        enum CodingKeys: String, CodingKey {
            case ip, name
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ip = c.lenient(.ip, default: "")
            name = c.lenient(.name, default: "")
        }
    }

    public struct Reply: Decodable, Sendable, Equatable {
        public var type = ""
        public var time = 0.0

        public init() {}

        enum CodingKeys: String, CodingKey {
            case type, time
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = c.lenient(.type, default: "")
            time = c.lenient(.time, default: 0.0)
        }
    }

    public var id: Int64 = 0
    public var time = 0.0
    public var type = ""
    public var domain = ""
    public var cname = ""
    public var status = ""
    public var client = Client()
    public var dnssec = ""
    public var reply = Reply()
    public var listID: Int64?
    public var upstream = ""

    public init() {}

    enum CodingKeys: String, CodingKey {
        case id, time, type, domain, cname, status, client, dnssec, reply, upstream
        case listID = "list_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, default: 0)
        time = c.lenient(.time, default: 0.0)
        type = c.lenient(.type, default: "")
        domain = c.lenient(.domain, default: "")
        cname = c.lenient(.cname, default: "")
        status = c.lenient(.status, default: "")
        client = c.lenient(.client, default: Client())
        dnssec = c.lenient(.dnssec, default: "")
        reply = c.lenient(.reply, default: Reply())
        listID = c.optional(.listID)
        upstream = c.lenient(.upstream, default: "")
    }
}

/// Response of `GET /api/queries`, including cursor-pagination metadata.
public struct QueriesPage: Decodable, Sendable, Equatable {
    public var queries: [DNSQuery] = []
    public var cursor: Int64?
    public var recordsFiltered = 0
    public var recordsTotal = 0
    public var draftCursor: Int64?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case queries, cursor, recordsFiltered, recordsTotal
        case draftCursor = "draft_cursor"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        queries = c.lenient(.queries, default: [])
        cursor = c.optional(.cursor)
        recordsFiltered = c.lenient(.recordsFiltered, default: 0)
        recordsTotal = c.lenient(.recordsTotal, default: 0)
        draftCursor = c.optional(.draftCursor)
    }
}

// MARK: - Blocking

/// Response of `GET /api/dns/blocking`.
///
/// FTL v6 reports the state as a status *string* on this GET ("enabled",
/// "disabled", "failure", "unknown") even though the matching POST body takes
/// a boolean. `status` keeps the raw value; `isBlocking` is true only for
/// "enabled". `timer` is the seconds until blocking flips back, or nil.
public struct BlockingStatus: Decodable, Sendable, Equatable {
    public var isBlocking = false
    public var status = ""
    public var timer: Double?

    public init() {}

    public init(isBlocking: Bool, status: String, timer: Double?) {
        self.isBlocking = isBlocking
        self.status = status
        self.timer = timer
    }

    enum CodingKeys: String, CodingKey {
        case blocking, timer
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.lenient(.blocking, default: "")
        isBlocking = status == "enabled"
        timer = c.optional(.timer)
    }
}

// MARK: - Domains

/// Allow/deny classification of a managed domain.
public enum DomainType: String, Codable, Sendable, CaseIterable {
    case allow
    case deny
}

/// Exact-match versus regex domains.
public enum DomainKind: String, Codable, Sendable, CaseIterable {
    case exact
    case regex
}

/// A managed allow/deny domain entry.
public struct ManagedDomain: Decodable, Sendable, Equatable, Identifiable {
    public var domain = ""
    public var unicode = ""
    public var type = ""
    public var kind = ""
    public var comment = ""
    public var groups: [Int] = []
    public var enabled = false
    public var id = 0
    public var dateAdded: Int64 = 0
    public var dateModified: Int64 = 0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case domain, unicode, type, kind, comment, groups, enabled, id
        case dateAdded = "date_added"
        case dateModified = "date_modified"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        domain = c.lenient(.domain, default: "")
        unicode = c.lenient(.unicode, default: "")
        type = c.lenient(.type, default: "")
        kind = c.lenient(.kind, default: "")
        comment = c.lenient(.comment, default: "")
        groups = c.lenient(.groups, default: [])
        enabled = c.lenient(.enabled, default: false)
        id = c.lenient(.id, default: 0)
        dateAdded = c.lenient(.dateAdded, default: 0)
        dateModified = c.lenient(.dateModified, default: 0)
    }

    public var domainType: DomainType { DomainType(rawValue: type) ?? .deny }
    public var domainKind: DomainKind { DomainKind(rawValue: kind) ?? .exact }

    /// The unicode form when FTL provides one, otherwise the stored domain.
    public var displayName: String {
        unicode.trimmingCharacters(in: .whitespaces).isEmpty ? domain : unicode
    }
}

struct DomainsEnvelope: Decodable {
    var domains: [ManagedDomain] = []

    enum CodingKeys: String, CodingKey {
        case domains
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        domains = c.lenient(.domains, default: [])
    }
}

// MARK: - Groups

/// An FTL group used to scope domains, clients, and lists.
public struct PiholeGroup: Decodable, Sendable, Equatable, Identifiable {
    public var name = ""
    public var comment = ""
    public var enabled = false
    public var id = 0
    public var dateAdded: Int64 = 0
    public var dateModified: Int64 = 0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case name, comment, enabled, id
        case dateAdded = "date_added"
        case dateModified = "date_modified"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.lenient(.name, default: "")
        comment = c.lenient(.comment, default: "")
        enabled = c.lenient(.enabled, default: false)
        id = c.lenient(.id, default: 0)
        dateAdded = c.lenient(.dateAdded, default: 0)
        dateModified = c.lenient(.dateModified, default: 0)
    }
}

struct GroupsEnvelope: Decodable {
    var groups: [PiholeGroup] = []

    enum CodingKeys: String, CodingKey {
        case groups
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = c.lenient(.groups, default: [])
    }
}

// MARK: - Clients

/// An FTL client record: maps an IP, subnet, MAC, or hostname to groups.
public struct ClientEntry: Decodable, Sendable, Equatable, Identifiable {
    public var client = ""
    public var comment = ""
    public var groups: [Int] = []
    public var id = 0
    public var name = ""
    public var dateAdded: Int64 = 0
    public var dateModified: Int64 = 0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case client, comment, groups, id, name
        case dateAdded = "date_added"
        case dateModified = "date_modified"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        client = c.lenient(.client, default: "")
        comment = c.lenient(.comment, default: "")
        groups = c.lenient(.groups, default: [])
        id = c.lenient(.id, default: 0)
        name = c.lenient(.name, default: "")
        dateAdded = c.lenient(.dateAdded, default: 0)
        dateModified = c.lenient(.dateModified, default: 0)
    }
}

/// A client seen in queries but not yet configured, from
/// `GET /api/clients/_suggestions`.
public struct ClientSuggestion: Decodable, Sendable, Equatable {
    public var hwaddr = ""
    public var macVendor = ""
    public var lastQuery: Int64 = 0
    public var name = ""
    public var addresses = ""

    public init() {}

    enum CodingKeys: String, CodingKey {
        case hwaddr, macVendor, lastQuery, name, addresses
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hwaddr = c.lenient(.hwaddr, default: "")
        macVendor = c.lenient(.macVendor, default: "")
        lastQuery = c.lenient(.lastQuery, default: 0)
        name = c.lenient(.name, default: "")
        addresses = c.lenient(.addresses, default: "")
    }
}

struct ClientsEnvelope: Decodable {
    var clients: [ClientEntry] = []

    enum CodingKeys: String, CodingKey {
        case clients
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clients = c.lenient(.clients, default: [])
    }
}

struct SuggestionsEnvelope: Decodable {
    var clients: [ClientSuggestion] = []

    enum CodingKeys: String, CodingKey {
        case clients
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clients = c.lenient(.clients, default: [])
    }
}

// MARK: - Adlists

/// Allow/block classification of a subscribed list.
public enum ListType: String, Codable, Sendable, CaseIterable {
    case allow
    case block
}

/// A subscribed adlist.
public struct Adlist: Decodable, Sendable, Equatable, Identifiable {
    public var address = ""
    public var comment = ""
    public var type = ""
    public var groups: [Int] = []
    public var enabled = false
    public var id = 0
    public var number = 0
    public var invalidDomains = 0
    public var status = 0
    public var dateAdded: Int64 = 0
    public var dateModified: Int64 = 0
    public var dateUpdated: Int64 = 0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case address, comment, type, groups, enabled, id, number, status
        case invalidDomains = "invalid_domains"
        case dateAdded = "date_added"
        case dateModified = "date_modified"
        case dateUpdated = "date_updated"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        address = c.lenient(.address, default: "")
        comment = c.lenient(.comment, default: "")
        type = c.lenient(.type, default: "")
        groups = c.lenient(.groups, default: [])
        enabled = c.lenient(.enabled, default: false)
        id = c.lenient(.id, default: 0)
        number = c.lenient(.number, default: 0)
        invalidDomains = c.lenient(.invalidDomains, default: 0)
        status = c.lenient(.status, default: 0)
        dateAdded = c.lenient(.dateAdded, default: 0)
        dateModified = c.lenient(.dateModified, default: 0)
        dateUpdated = c.lenient(.dateUpdated, default: 0)
    }

    public var listType: ListType { ListType(rawValue: type) ?? .block }
}

struct ListsEnvelope: Decodable {
    var lists: [Adlist] = []

    enum CodingKeys: String, CodingKey {
        case lists
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lists = c.lenient(.lists, default: [])
    }
}

// MARK: - Info

/// An FTL diagnosis message from `GET /api/info/messages`.
public struct DiagnosisMessage: Decodable, Sendable, Equatable, Identifiable {
    public var id = 0
    public var timestamp = 0.0
    public var type = ""
    public var plain = ""
    public var html = ""
    public var url = ""

    public init() {}

    enum CodingKeys: String, CodingKey {
        case id, timestamp, type, plain, html, url
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, default: 0)
        timestamp = c.lenient(.timestamp, default: 0.0)
        type = c.lenient(.type, default: "")
        plain = c.lenient(.plain, default: "")
        html = c.lenient(.html, default: "")
        url = c.lenient(.url, default: "")
    }
}

struct MessagesEnvelope: Decodable {
    var messages: [DiagnosisMessage] = []

    enum CodingKeys: String, CodingKey {
        case messages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = c.lenient(.messages, default: [])
    }
}

struct MessageCountEnvelope: Decodable {
    var count = 0

    enum CodingKeys: String, CodingKey {
        case count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = c.lenient(.count, default: 0)
    }
}

/// A single line of the FTL DNS resolver log.
public struct DNSLogLine: Decodable, Sendable, Equatable {
    public var timestamp = 0.0
    public var message = ""
    public var prio = ""

    public init() {}

    enum CodingKeys: String, CodingKey {
        case timestamp, message, prio
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = c.lenient(.timestamp, default: 0.0)
        message = c.lenient(.message, default: "")
        prio = c.lenient(.prio, default: "")
    }
}

/// Response of `GET /api/info/logs/dns`: a batch of lines plus the cursor for
/// the next batch.
public struct DNSLogPage: Decodable, Sendable, Equatable {
    public var log: [DNSLogLine] = []
    public var nextID = 0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case log, nextID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        log = c.lenient(.log, default: [])
        nextID = c.lenient(.nextID, default: 0)
    }
}

// MARK: - Network

/// An IP/name pair observed for a network device.
public struct NetworkAddress: Decodable, Sendable, Equatable {
    public var ip = ""
    public var name = ""
    public var lastSeen: Int64 = 0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case ip, name, lastSeen
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ip = c.lenient(.ip, default: "")
        name = c.lenient(.name, default: "")
        lastSeen = c.lenient(.lastSeen, default: 0)
    }
}

/// A device row from `GET /api/network/devices`.
public struct NetworkDevice: Decodable, Sendable, Equatable, Identifiable {
    public var id = 0
    public var hwaddr = ""
    public var interface = ""
    public var firstSeen: Int64 = 0
    public var lastQuery: Int64 = 0
    public var numQueries = 0
    public var macVendor = ""
    public var ips: [NetworkAddress] = []

    public init() {}

    enum CodingKeys: String, CodingKey {
        case id, hwaddr, interface, firstSeen, lastQuery, numQueries, macVendor, ips
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, default: 0)
        hwaddr = c.lenient(.hwaddr, default: "")
        interface = c.lenient(.interface, default: "")
        firstSeen = c.lenient(.firstSeen, default: 0)
        lastQuery = c.lenient(.lastQuery, default: 0)
        numQueries = c.lenient(.numQueries, default: 0)
        macVendor = c.lenient(.macVendor, default: "")
        ips = c.lenient(.ips, default: [])
    }
}

struct NetworkDevicesEnvelope: Decodable {
    var devices: [NetworkDevice] = []

    enum CodingKeys: String, CodingKey {
        case devices
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        devices = c.lenient(.devices, default: [])
    }
}

// MARK: - System

/// The dashboard-relevant slice of `GET /api/info/system`.
public struct SystemInfo: Sendable, Equatable {
    /// Host uptime in seconds.
    public var uptime: Int64 = 0
    /// Number of running processes.
    public var procs = 0
    /// Number of CPU cores/threads.
    public var nprocs = 0
    /// Host-wide CPU utilization (0...100).
    public var cpuPercent = 0.0
    /// 1-minute load average as a percent of total CPU capacity (0...100).
    public var load1Percent = 0.0
    /// RAM utilization (0...100).
    public var memUsedPercent = 0.0
    /// RAM figures in kibibytes, as FTL reports them.
    public var memUsedKiB: Int64 = 0
    public var memTotalKiB: Int64 = 0
    /// Swap utilization (0...100).
    public var swapUsedPercent = 0.0
    /// pihole-FTL's own resource usage.
    public var ftlCPUPercent = 0.0
    public var ftlMemPercent = 0.0

    public init() {}
}

extension SystemInfo: Decodable {
    public init(from decoder: Decoder) throws {
        let root = try JSONValue(from: decoder)
        let system = root["system"] ?? .null

        func number(_ path: String) -> Double {
            system.value(atPath: path)?.numberValue ?? 0
        }

        uptime = Int64(number("uptime"))
        procs = Int(number("procs"))
        nprocs = Int(number("cpu.nprocs"))
        cpuPercent = system["cpu"]?["%cpu"]?.numberValue ?? 0
        load1Percent = system["cpu"]?["load"]?["percent"]?.arrayValue?.first?.numberValue ?? 0
        memUsedPercent = system["memory"]?["ram"]?["%used"]?.numberValue ?? 0
        memUsedKiB = Int64(number("memory.ram.used"))
        memTotalKiB = Int64(number("memory.ram.total"))
        swapUsedPercent = system["memory"]?["swap"]?["%used"]?.numberValue ?? 0
        ftlCPUPercent = system["ftl"]?["%cpu"]?.numberValue ?? 0
        ftlMemPercent = system["ftl"]?["%mem"]?.numberValue ?? 0
    }
}

/// The dashboard-relevant slice of `GET /api/info/sensors`.
public struct Sensors: Sendable, Equatable {
    /// False when the host exposes no readable temperature sensor.
    public var hasTemp = false
    /// Primary CPU temperature in `unit`.
    public var cpuTemp = 0.0
    /// The temperature FTL considers hot (drives the gauge scale).
    public var hotLimit = 0.0
    /// Temperature unit letter ("C", "F", "K").
    public var unit = ""

    public init() {}

    public init(hasTemp: Bool, cpuTemp: Double, hotLimit: Double, unit: String) {
        self.hasTemp = hasTemp
        self.cpuTemp = cpuTemp
        self.hotLimit = hotLimit
        self.unit = unit
    }
}

extension Sensors: Decodable {
    public init(from decoder: Decoder) throws {
        let root = try JSONValue(from: decoder)
        let sensors = root["sensors"] ?? .null
        hotLimit = sensors["hot_limit"]?.numberValue ?? 0
        unit = sensors["unit"]?.stringValue ?? ""
        if let temp = sensors["cpu_temp"]?.numberValue {
            hasTemp = true
            cpuTemp = temp
        }
    }
}

// MARK: - Local DNS

/// A local A/AAAA host entry, stored in `dns.hosts` as "IP domain".
public struct HostRecord: Sendable, Equatable, Hashable, Identifiable {
    public let ip: String
    public let domain: String
    /// The config string exactly as FTL stores it. Deletes send this, so an
    /// entry with tabs or extra spaces still matches.
    public let configValue: String

    public init(ip: String = "", domain: String = "") {
        self.ip = ip
        self.domain = domain
        self.configValue = ip + " " + domain
    }

    public var id: String { configValue }

    /// Splits an "IP domain" config string. The separator is whitespace; the
    /// domain is everything after the first field.
    public init(configValue: String) {
        let fields = configValue
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        ip = fields.first ?? ""
        domain = fields.dropFirst().joined(separator: " ")
        self.configValue = configValue
    }
}

/// A local CNAME entry, stored in `dns.cnameRecords` as "domain,target[,ttl]".
public struct CNAMERecord: Sendable, Equatable, Hashable, Identifiable {
    public let domain: String
    public let target: String
    public let ttl: Int
    /// The config string exactly as FTL stores it. Deletes send this, so an
    /// entry with spaces after the commas still matches.
    public let configValue: String

    /// A non-positive ttl is left out of the config string.
    public init(domain: String = "", target: String = "", ttl: Int = 0) {
        self.domain = domain
        self.target = target
        self.ttl = ttl
        self.configValue = ttl > 0
            ? "\(domain),\(target),\(ttl)"
            : "\(domain),\(target)"
    }

    public var id: String { configValue }

    /// Splits a "domain,target[,ttl]" config string. A malformed or absent
    /// ttl yields 0.
    public init(configValue: String) {
        let parts = configValue
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        domain = parts.count > 0 ? parts[0] : ""
        target = parts.count > 1 ? parts[1] : ""
        ttl = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
        self.configValue = configValue
    }
}

// MARK: - Config

struct ConfigEnvelope: Decodable {
    var config: JSONValue = .object([:])

    enum CodingKeys: String, CodingKey {
        case config
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        config = c.lenient(.config, default: .object([:]))
    }
}

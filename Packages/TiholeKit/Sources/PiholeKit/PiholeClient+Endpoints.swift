import Foundation

// One method per FTL endpoint, in the same order as the Go client's files.

// MARK: - Query filter

/// Optional filter and cursor-pagination parameters for `GET /api/queries`.
/// Only the fields that are set are sent.
public struct QueryFilter: Sendable, Equatable {
    /// Number of records to return.
    public var length: Int?
    /// Offset into the result set.
    public var start: Int?
    /// Pagination cursor from a prior page.
    public var cursor: Int64?
    /// Unix timestamp lower bound.
    public var from: Int64?
    /// Unix timestamp upper bound.
    public var until: Int64?
    public var domain: String?
    public var clientIP: String?
    public var clientName: String?
    public var upstream: String?
    public var type: String?
    public var status: String?
    public var reply: String?
    public var dnssec: String?
    /// Include on-disk (long-term) database records.
    public var disk: Bool?

    public init(
        length: Int? = nil,
        start: Int? = nil,
        cursor: Int64? = nil,
        from: Int64? = nil,
        until: Int64? = nil,
        domain: String? = nil,
        clientIP: String? = nil,
        clientName: String? = nil,
        upstream: String? = nil,
        type: String? = nil,
        status: String? = nil,
        reply: String? = nil,
        dnssec: String? = nil,
        disk: Bool? = nil
    ) {
        self.length = length
        self.start = start
        self.cursor = cursor
        self.from = from
        self.until = until
        self.domain = domain
        self.clientIP = clientIP
        self.clientName = clientName
        self.upstream = upstream
        self.type = type
        self.status = status
        self.reply = reply
        self.dnssec = dnssec
        self.disk = disk
    }

    /// The set fields as query parameters.
    var items: [(String, String)] {
        var out: [(String, String)] = []
        if let length { out.append(("length", String(length))) }
        if let start { out.append(("start", String(start))) }
        if let cursor { out.append(("cursor", String(cursor))) }
        if let from { out.append(("from", String(from))) }
        if let until { out.append(("until", String(until))) }
        if let domain { out.append(("domain", domain)) }
        if let clientIP { out.append(("client_ip", clientIP)) }
        if let clientName { out.append(("client_name", clientName)) }
        if let upstream { out.append(("upstream", upstream)) }
        if let type { out.append(("type", type)) }
        if let status { out.append(("status", status)) }
        if let reply { out.append(("reply", reply)) }
        if let dnssec { out.append(("dnssec", dnssec)) }
        if let disk { out.append(("disk", disk ? "true" : "false")) }
        return out
    }
}

// MARK: - Request bodies

private struct BlockingRequest: Encodable {
    let blocking: Bool
    let timer: Double?

    enum CodingKeys: String, CodingKey {
        case blocking, timer
    }

    // FTL expects an explicit `"timer": null` for a permanent change.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(blocking, forKey: .blocking)
        if let timer {
            try c.encode(timer, forKey: .timer)
        } else {
            try c.encodeNil(forKey: .timer)
        }
    }
}

private struct DomainCreateRequest: Encodable {
    let domain: String
    let comment: String
    let groups: [Int]?
    let enabled: Bool
}

private struct DomainUpdateRequest: Encodable {
    let comment: String
    let groups: [Int]
    let enabled: Bool
}

private struct GroupCreateRequest: Encodable {
    let name: String
    let comment: String
    let enabled: Bool
}

private struct GroupUpdateRequest: Encodable {
    let comment: String
    let enabled: Bool
}

private struct ClientCreateRequest: Encodable {
    let client: String
    let comment: String
    let groups: [Int]
}

private struct ClientUpdateRequest: Encodable {
    let comment: String
    let groups: [Int]
}

private struct ListCreateRequest: Encodable {
    let address: String
    let type: ListType
    let comment: String
    let groups: [Int]
    let enabled: Bool
}

private struct ListUpdateRequest: Encodable {
    let type: ListType
    let comment: String
    let groups: [Int]
    let enabled: Bool
}

private struct ConfigPatchRequest: Encodable {
    let config: JSONValue
}

extension PiholeClient {
    // MARK: - Blocking

    /// `GET /api/dns/blocking`: the current blocking state and any active
    /// countdown timer.
    public func blocking() async throws -> BlockingStatus {
        let data = try await perform("GET", "/dns/blocking")
        return try decode(BlockingStatus.self, from: data, operation: "GET /dns/blocking")
    }

    /// `POST /api/dns/blocking`. `timer` is the number of seconds after which
    /// blocking reverts, or nil for a permanent change.
    public func setBlocking(_ blocking: Bool, timer: Double? = nil) async throws {
        let body = try encodeJSON(BlockingRequest(blocking: blocking, timer: timer))
        _ = try await perform("POST", "/dns/blocking", body: body)
    }

    // MARK: - Stats

    /// `GET /api/stats/summary`.
    public func summary() async throws -> Summary {
        let data = try await perform("GET", "/stats/summary")
        return try decode(Summary.self, from: data, operation: "GET /stats/summary")
    }

    /// `GET /api/stats/upstreams`.
    public func upstreams() async throws -> Upstreams {
        let data = try await perform("GET", "/stats/upstreams")
        return try decode(Upstreams.self, from: data, operation: "GET /stats/upstreams")
    }

    /// `GET /api/stats/query_types`.
    public func queryTypes() async throws -> QueryTypes {
        let data = try await perform("GET", "/stats/query_types")
        return try decode(QueryTypes.self, from: data, operation: "GET /stats/query_types")
    }

    /// `GET /api/stats/top_domains`. A non-positive `count` omits the
    /// parameter (server default).
    public func topDomains(blocked: Bool, count: Int = 0) async throws -> TopDomains {
        let path = "/stats/top_domains" + PiholeClient.topQuery(blocked: blocked, count: count)
        let data = try await perform("GET", path)
        return try decode(TopDomains.self, from: data, operation: "GET /stats/top_domains")
    }

    /// `GET /api/stats/top_clients`. A non-positive `count` omits the
    /// parameter (server default).
    public func topClients(blocked: Bool, count: Int = 0) async throws -> TopClients {
        let path = "/stats/top_clients" + PiholeClient.topQuery(blocked: blocked, count: count)
        let data = try await perform("GET", path)
        return try decode(TopClients.self, from: data, operation: "GET /stats/top_clients")
    }

    static func topQuery(blocked: Bool, count: Int) -> String {
        var items = [("blocked", blocked ? "true" : "false")]
        if count > 0 {
            items.append(("count", String(count)))
        }
        return Escape.queryString(items)
    }

    // MARK: - History

    /// `GET /api/history`: queries-over-time buckets.
    public func history() async throws -> QueryHistory {
        let data = try await perform("GET", "/history")
        return try decode(QueryHistory.self, from: data, operation: "GET /history")
    }

    // MARK: - Queries

    /// `GET /api/queries` with cursor pagination.
    public func queries(_ filter: QueryFilter = QueryFilter()) async throws -> QueriesPage {
        let path = "/queries" + Escape.queryString(filter.items)
        let data = try await perform("GET", path)
        return try decode(QueriesPage.self, from: data, operation: "GET /queries")
    }

    // MARK: - Domains

    static func domainPath(_ type: DomainType, _ kind: DomainKind, _ domain: String) -> String {
        "/domains/\(type.rawValue)/\(kind.rawValue)/\(Escape.segment(domain))"
    }

    /// `GET /api/domains`: every managed allow/deny domain.
    public func domains() async throws -> [ManagedDomain] {
        let data = try await perform("GET", "/domains")
        return try decode(DomainsEnvelope.self, from: data, operation: "GET /domains").domains
    }

    /// `POST /api/domains/{type}/{kind}`. FTL requires the item in the body on
    /// POST. The new entry is created enabled; nil `groups` leaves the group
    /// assignment to the server default.
    @discardableResult
    public func addDomain(
        type: DomainType,
        kind: DomainKind,
        domain: String,
        comment: String = "",
        groups: [Int]? = nil
    ) async throws -> ManagedDomain {
        let body = try encodeJSON(
            DomainCreateRequest(domain: domain, comment: comment, groups: groups, enabled: true)
        )
        let path = "/domains/\(type.rawValue)/\(kind.rawValue)"
        let data = try await perform("POST", path, body: body)
        let envelope = try decode(DomainsEnvelope.self, from: data, operation: "POST " + path)
        return envelope.domains.first ?? ManagedDomain()
    }

    /// `PUT /api/domains/{type}/{kind}/{domain}`.
    @discardableResult
    public func updateDomain(
        type: DomainType,
        kind: DomainKind,
        domain: String,
        comment: String,
        groups: [Int],
        enabled: Bool
    ) async throws -> ManagedDomain {
        let body = try encodeJSON(
            DomainUpdateRequest(comment: comment, groups: groups, enabled: enabled)
        )
        let path = PiholeClient.domainPath(type, kind, domain)
        let data = try await perform("PUT", path, body: body)
        let envelope = try decode(DomainsEnvelope.self, from: data, operation: "PUT /domains")
        return envelope.domains.first ?? ManagedDomain()
    }

    /// `DELETE /api/domains/{type}/{kind}/{domain}`.
    public func deleteDomain(type: DomainType, kind: DomainKind, domain: String) async throws {
        _ = try await perform("DELETE", PiholeClient.domainPath(type, kind, domain))
    }

    // MARK: - Groups

    /// `GET /api/groups`: every configured group.
    public func groups() async throws -> [PiholeGroup] {
        let data = try await perform("GET", "/groups")
        return try decode(GroupsEnvelope.self, from: data, operation: "GET /groups").groups
    }

    /// `POST /api/groups`. The new group is enabled.
    @discardableResult
    public func addGroup(name: String, comment: String = "") async throws -> PiholeGroup {
        let body = try encodeJSON(GroupCreateRequest(name: name, comment: comment, enabled: true))
        let data = try await perform("POST", "/groups", body: body)
        let envelope = try decode(GroupsEnvelope.self, from: data, operation: "POST /groups")
        return envelope.groups.first ?? PiholeGroup()
    }

    /// `PUT /api/groups/{name}`.
    @discardableResult
    public func updateGroup(name: String, comment: String, enabled: Bool) async throws -> PiholeGroup {
        let body = try encodeJSON(GroupUpdateRequest(comment: comment, enabled: enabled))
        let data = try await perform("PUT", "/groups/" + Escape.segment(name), body: body)
        let envelope = try decode(GroupsEnvelope.self, from: data, operation: "PUT /groups")
        return envelope.groups.first ?? PiholeGroup()
    }

    /// `DELETE /api/groups/{name}`.
    public func deleteGroup(name: String) async throws {
        _ = try await perform("DELETE", "/groups/" + Escape.segment(name))
    }

    // MARK: - Clients

    /// `GET /api/clients`: every configured client.
    public func clients() async throws -> [ClientEntry] {
        let data = try await perform("GET", "/clients")
        return try decode(ClientsEnvelope.self, from: data, operation: "GET /clients").clients
    }

    /// `POST /api/clients`.
    @discardableResult
    public func addClient(
        client: String,
        comment: String = "",
        groups: [Int] = [0]
    ) async throws -> ClientEntry {
        let body = try encodeJSON(
            ClientCreateRequest(client: client, comment: comment, groups: groups)
        )
        let data = try await perform("POST", "/clients", body: body)
        let envelope = try decode(ClientsEnvelope.self, from: data, operation: "POST /clients")
        return envelope.clients.first ?? ClientEntry()
    }

    /// `PUT /api/clients/{client}`.
    @discardableResult
    public func updateClient(
        client: String,
        comment: String,
        groups: [Int]
    ) async throws -> ClientEntry {
        let body = try encodeJSON(ClientUpdateRequest(comment: comment, groups: groups))
        let data = try await perform("PUT", "/clients/" + Escape.segment(client), body: body)
        let envelope = try decode(ClientsEnvelope.self, from: data, operation: "PUT /clients")
        return envelope.clients.first ?? ClientEntry()
    }

    /// `DELETE /api/clients/{client}`.
    public func deleteClient(client: String) async throws {
        _ = try await perform("DELETE", "/clients/" + Escape.segment(client))
    }

    /// `GET /api/clients/_suggestions`: clients seen in queries that are not
    /// yet configured.
    public func clientSuggestions() async throws -> [ClientSuggestion] {
        let data = try await perform("GET", "/clients/_suggestions")
        return try decode(
            SuggestionsEnvelope.self,
            from: data,
            operation: "GET /clients/_suggestions"
        ).clients
    }

    // MARK: - Adlists

    static func listPath(_ address: String, _ type: ListType) -> String {
        "/lists/" + Escape.segment(address) + "?type=" + Escape.query(type.rawValue)
    }

    /// `GET /api/lists?type={type}`.
    public func lists(type: ListType) async throws -> [Adlist] {
        let data = try await perform("GET", "/lists?type=" + Escape.query(type.rawValue))
        return try decode(ListsEnvelope.self, from: data, operation: "GET /lists").lists
    }

    /// `POST /api/lists`. The new list is enabled.
    @discardableResult
    public func addList(
        address: String,
        type: ListType,
        comment: String = "",
        groups: [Int] = [0]
    ) async throws -> Adlist {
        let body = try encodeJSON(
            ListCreateRequest(
                address: address,
                type: type,
                comment: comment,
                groups: groups,
                enabled: true
            )
        )
        let data = try await perform("POST", "/lists", body: body)
        let envelope = try decode(ListsEnvelope.self, from: data, operation: "POST /lists")
        return envelope.lists.first ?? Adlist()
    }

    /// `PUT /api/lists/{address}?type={type}`.
    @discardableResult
    public func updateList(
        address: String,
        type: ListType,
        comment: String,
        groups: [Int],
        enabled: Bool
    ) async throws -> Adlist {
        let body = try encodeJSON(
            ListUpdateRequest(type: type, comment: comment, groups: groups, enabled: enabled)
        )
        let data = try await perform("PUT", PiholeClient.listPath(address, type), body: body)
        let envelope = try decode(ListsEnvelope.self, from: data, operation: "PUT /lists")
        return envelope.lists.first ?? Adlist()
    }

    /// `DELETE /api/lists/{address}?type={type}`.
    public func deleteList(address: String, type: ListType) async throws {
        _ = try await perform("DELETE", PiholeClient.listPath(address, type))
    }

    // MARK: - Config

    /// `GET /api/config`: the full configuration tree. With `detailed`, FTL
    /// annotates each leaf with metadata (type, description, default,
    /// allowed values); otherwise raw values are returned.
    public func config(detailed: Bool) async throws -> JSONValue {
        let path = "/config?detailed=" + (detailed ? "true" : "false")
        let data = try await perform("GET", path)
        return try decode(ConfigEnvelope.self, from: data, operation: "GET /config").config
    }

    /// `GET /api/config/{element}`: a single subtree addressed by a dotted
    /// path such as "dns.upstreams". The result mirrors the element's path
    /// (`{"dns": {"upstreams": [...]}}`).
    public func configElement(_ element: String) async throws -> JSONValue {
        let path = "/config/" + Escape.element(element)
        let data = try await perform("GET", path)
        return try decode(ConfigEnvelope.self, from: data, operation: "GET " + path).config
    }

    /// `PATCH /api/config`. The patch is sent under the `config` key. With
    /// `restart`, FTL restarts affected subsystems to apply it immediately.
    public func patchConfig(_ patch: JSONValue, restart: Bool = false) async throws {
        let path = "/config?restart=" + (restart ? "true" : "false")
        let body = try encodeJSON(ConfigPatchRequest(config: patch))
        _ = try await perform("PATCH", path, body: body)
    }

    /// `PUT /api/config/{element}/{value}`: appends `value` to an array-valued
    /// config element.
    public func addConfigItem(element: String, value: String) async throws {
        let path = "/config/" + Escape.element(element) + "/" + Escape.segment(value)
        _ = try await perform("PUT", path)
    }

    /// `DELETE /api/config/{element}/{value}`: removes `value` from an
    /// array-valued config element.
    public func deleteConfigItem(element: String, value: String) async throws {
        let path = "/config/" + Escape.element(element) + "/" + Escape.segment(value)
        _ = try await perform("DELETE", path)
    }

    /// Fetches a config element whose value is an array of strings, ignoring
    /// any non-string entries.
    func stringArrayElement(_ element: String) async throws -> [String] {
        let tree = try await configElement(element)
        guard let items = tree.value(atPath: element)?.arrayValue else {
            return []
        }
        return items.compactMap { $0.stringValue }
    }

    // MARK: - Local DNS

    /// The `dns.hosts` config element, parsed into host records.
    public func hostRecords() async throws -> [HostRecord] {
        try await stringArrayElement("dns.hosts").map { HostRecord(configValue: $0) }
    }

    /// `PUT /api/config/dns/hosts/{IP domain}`.
    public func addHostRecord(ip: String, domain: String) async throws {
        try await addConfigItem(
            element: "dns.hosts",
            value: HostRecord(ip: ip, domain: domain).configValue
        )
    }

    /// `DELETE /api/config/dns/hosts/{IP domain}`, sending the record's
    /// stored string unchanged.
    public func deleteHostRecord(_ record: HostRecord) async throws {
        try await deleteConfigItem(element: "dns.hosts", value: record.configValue)
    }

    /// The `dns.cnameRecords` config element, parsed into CNAME records.
    public func cnameRecords() async throws -> [CNAMERecord] {
        try await stringArrayElement("dns.cnameRecords").map { CNAMERecord(configValue: $0) }
    }

    /// `PUT /api/config/dns/cnameRecords/{value}`. A non-positive ttl is
    /// omitted.
    public func addCNAMERecord(domain: String, target: String, ttl: Int = 0) async throws {
        try await addConfigItem(
            element: "dns.cnameRecords",
            value: CNAMERecord(domain: domain, target: target, ttl: ttl).configValue
        )
    }

    /// `DELETE /api/config/dns/cnameRecords/{value}`, sending the record's
    /// stored string unchanged.
    public func deleteCNAMERecord(_ record: CNAMERecord) async throws {
        try await deleteConfigItem(element: "dns.cnameRecords", value: record.configValue)
    }

    // MARK: - Info

    /// `GET /api/info/{section}` for section in ftl, host, system, version,
    /// metrics, sensors, database. Returns the section object (FTL nests it
    /// under a key matching the section name).
    public func info(_ section: String) async throws -> JSONValue {
        let path = "/info/" + Escape.segment(section)
        let data = try await perform("GET", path)
        let raw = try decode(JSONValue.self, from: data, operation: "GET " + path)
        if let inner = raw[section], inner.objectValue != nil {
            return inner
        }
        guard var object = raw.objectValue else {
            return raw
        }
        object.removeValue(forKey: "took")
        return .object(object)
    }

    /// `GET /api/info/messages/count`: the number of active diagnosis
    /// messages.
    public func messageCount() async throws -> Int {
        let data = try await perform("GET", "/info/messages/count")
        return try decode(
            MessageCountEnvelope.self,
            from: data,
            operation: "GET /info/messages/count"
        ).count
    }

    /// `GET /api/info/messages`: the active diagnosis messages.
    public func messages() async throws -> [DiagnosisMessage] {
        let data = try await perform("GET", "/info/messages")
        return try decode(
            MessagesEnvelope.self,
            from: data,
            operation: "GET /info/messages"
        ).messages
    }

    /// `DELETE /api/info/messages/{ids}` with the ids comma-joined into one
    /// path segment. An empty list is a no-op.
    public func deleteMessages(ids: [Int]) async throws {
        if ids.isEmpty { return }
        let joined = ids.map { String($0) }.joined(separator: ",")
        _ = try await perform("DELETE", "/info/messages/" + joined)
    }

    /// `GET /api/info/logs/dns` for the live resolver log tail. A positive
    /// `nextID` is sent as the cursor; otherwise the request starts from the
    /// beginning of the available window.
    public func dnsLog(nextID: Int = 0) async throws -> DNSLogPage {
        var path = "/info/logs/dns"
        if nextID > 0 {
            path += "?nextID=\(nextID)"
        }
        let data = try await perform("GET", path)
        return try decode(DNSLogPage.self, from: data, operation: "GET /info/logs/dns")
    }

    /// `GET /api/info/system`, reduced to the fields the dashboard's health
    /// strip renders.
    public func system() async throws -> SystemInfo {
        let data = try await perform("GET", "/info/system")
        return try decode(SystemInfo.self, from: data, operation: "GET /info/system")
    }

    /// `GET /api/info/sensors`. When the host reports no CPU temperature,
    /// `hasTemp` is false and callers should hide the gauge.
    public func sensors() async throws -> Sensors {
        let data = try await perform("GET", "/info/sensors")
        return try decode(Sensors.self, from: data, operation: "GET /info/sensors")
    }

    // MARK: - Network

    /// `GET /api/network/devices`: every device FTL has seen on the local
    /// network.
    public func networkDevices() async throws -> [NetworkDevice] {
        let data = try await perform("GET", "/network/devices")
        return try decode(
            NetworkDevicesEnvelope.self,
            from: data,
            operation: "GET /network/devices"
        ).devices
    }

    /// `DELETE /api/network/devices/{id}`.
    public func deleteNetworkDevice(id: Int) async throws {
        _ = try await perform("DELETE", "/network/devices/\(id)")
    }

    // MARK: - Actions

    // These are destructive and return a 403 unless the FTL webserver has
    // `webserver.api.allow_destructive` enabled.

    /// `POST /api/action/restartdns`.
    public func restartDNS() async throws {
        _ = try await perform("POST", "/action/restartdns")
    }

    /// `POST /api/action/flush/logs`.
    public func flushLogs() async throws {
        _ = try await perform("POST", "/action/flush/logs")
    }

    /// `POST /api/action/flush/network`.
    public func flushNetwork() async throws {
        _ = try await perform("POST", "/action/flush/network")
    }
}

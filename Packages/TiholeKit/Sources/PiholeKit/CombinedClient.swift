import Foundation

/// A merged read result plus the members that could not contribute to it.
public struct Combined<Value: Sendable>: Sendable {
    public var value: Value
    /// Names of the members that failed, in member order. Empty when every
    /// member answered.
    public var failed: [String]

    public init(value: Value, failed: [String] = []) {
        self.value = value
        self.failed = failed
    }
}

/// Every configured Pi-hole read as one network. People run several Pi-holes
/// for redundancy, so each one sees only part of the traffic.
///
/// Only the read calls the dashboard and query log use are offered. Writes
/// have no combined meaning here and go to the active instance's client.
/// Mirrors tihole's `pihole.Group`.
public struct CombinedClient: Sendable {
    public struct Member: Sendable {
        public let name: String
        public let client: PiholeClient

        public init(name: String, client: PiholeClient) {
            self.name = name
            self.client = client
        }
    }

    public let members: [Member]
    /// Instances that could not be built (no password, bad URL). They count
    /// as failed on every call.
    public let unavailable: [String]

    public init(members: [Member], unavailable: [String] = []) {
        self.members = members
        self.unavailable = unavailable
    }

    /// Runs `operation` on every member concurrently. Throws only when every
    /// member fails; otherwise returns the successes in member order.
    func fanOut<T: Sendable>(
        _ operation: @escaping @Sendable (PiholeClient) async throws -> T
    ) async throws -> (results: [(name: String, value: T)], failed: [String]) {
        let outcomes = await withTaskGroup(
            of: (Int, Result<T, Error>).self
        ) { group in
            for (index, member) in members.enumerated() {
                group.addTask {
                    do {
                        return (
                            index, .success(try await operation(member.client))
                        )
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var collected = [Result<T, Error>?](
                repeating: nil, count: members.count)
            for await (index, result) in group {
                collected[index] = result
            }
            return collected
        }

        var results: [(name: String, value: T)] = []
        var failed: [String] = []
        var firstError: Error?
        for (member, outcome) in zip(members, outcomes) {
            switch outcome {
            case .success(let value):
                results.append((member.name, value))
            case .failure(let error):
                failed.append(member.name)
                firstError = firstError ?? error
            case nil:
                failed.append(member.name)
            }
        }
        try Task.checkCancellation()
        if results.isEmpty {
            throw firstError
                ?? PiholeError.network(
                    operation: "combined",
                    underlying: URLError(.cannotConnectToHost))
        }
        return (results, failed + unavailable)
    }

    private func merged<T: Sendable, U: Sendable>(
        _ operation: @escaping @Sendable (PiholeClient) async throws -> T,
        _ merge: ([(name: String, value: T)]) -> U
    ) async throws -> Combined<U> {
        let (results, failed) = try await fanOut(operation)
        return Combined(value: merge(results), failed: failed)
    }

    public func summary() async throws -> Combined<Summary> {
        try await merged({ try await $0.summary() }) {
            Merge.summary($0.map(\.value))
        }
    }

    public func history() async throws -> Combined<QueryHistory> {
        try await merged({ try await $0.history() }) {
            Merge.history($0.map(\.value))
        }
    }

    public func queryTypes() async throws -> Combined<QueryTypes> {
        try await merged({ try await $0.queryTypes() }) {
            Merge.queryTypes($0.map(\.value))
        }
    }

    public func upstreams() async throws -> Combined<Upstreams> {
        try await merged({ try await $0.upstreams() }) {
            Merge.upstreams($0.map(\.value))
        }
    }

    // shortcut: top-N merge over-fetches 3x, exact only if each member
    // returns everything.
    public func topDomains(blocked: Bool, count: Int) async throws
        -> Combined<TopDomains>
    {
        try await merged({
            try await $0.topDomains(blocked: blocked, count: count * 3)
        }) {
            Merge.topDomains($0.map(\.value), count: count)
        }
    }

    public func topClients(blocked: Bool, count: Int) async throws
        -> Combined<TopClients>
    {
        try await merged({
            try await $0.topClients(blocked: blocked, count: count * 3)
        }) {
            Merge.topClients($0.map(\.value), count: count)
        }
    }

    /// The newest page from every member, merged newest first. Each row's
    /// `instance` names the Pi-hole that answered it.
    public func queries(_ filter: QueryFilter) async throws
        -> Combined<QueriesPage>
    {
        var memberFilter = filter
        memberFilter.cursor = nil
        let page = memberFilter
        return try await merged({ try await $0.queries(page) }) {
            Merge.queries($0, length: filter.length)
        }
    }
}

/// The pure merge rules behind `CombinedClient`. Counts add up, ratios are
/// recomputed from merged totals, and overlapping sets are never summed.
enum Merge {
    static func summary(_ parts: [Summary]) -> Summary {
        var out = Summary()
        for part in parts {
            out.queries.total += part.queries.total
            out.queries.blocked += part.queries.blocked
            out.queries.forwarded += part.queries.forwarded
            out.queries.cached += part.queries.cached
            out.queries.frequency += part.queries.frequency
            // Sets overlap and the API gives no set, so max is a lower bound.
            out.queries.uniqueDomains = max(
                out.queries.uniqueDomains, part.queries.uniqueDomains)
            // Devices usually query every Pi-hole; summing double-counts.
            out.clients.active = max(out.clients.active, part.clients.active)
            out.clients.total = max(out.clients.total, part.clients.total)
            out.gravity.domainsBeingBlocked = max(
                out.gravity.domainsBeingBlocked,
                part.gravity.domainsBeingBlocked)
        }
        out.queries.percentBlocked =
            out.queries.total > 0
            ? Double(out.queries.blocked) / Double(out.queries.total) * 100 : 0
        // The oldest, so a stale member shows.
        out.gravity.lastUpdate = parts.map(\.gravity.lastUpdate).min() ?? 0
        out.gravityMismatch =
            Set(parts.map(\.gravity.domainsBeingBlocked)).count > 1
        return out
    }

    static func history(_ parts: [QueryHistory]) -> QueryHistory {
        var buckets: [Int: HistoryPoint] = [:]
        for point in parts.flatMap(\.history) {
            var bucket = buckets[point.timestamp] ?? HistoryPoint()
            bucket.timestamp = point.timestamp
            bucket.total += point.total
            bucket.cached += point.cached
            bucket.blocked += point.blocked
            bucket.forwarded += point.forwarded
            buckets[point.timestamp] = bucket
        }
        var out = QueryHistory()
        out.history = buckets.values.sorted { $0.timestamp < $1.timestamp }
        return out
    }

    static func queryTypes(_ parts: [QueryTypes]) -> QueryTypes {
        var out = QueryTypes()
        for part in parts {
            out.types.merge(part.types, uniquingKeysWith: +)
        }
        return out
    }

    static func upstreams(_ parts: [Upstreams]) -> Upstreams {
        var order: [String] = []
        var byKey: [String: UpstreamServer] = [:]
        // Count-weighted sums, divided out at the end.
        var responseSum: [String: Double] = [:]
        var varianceSum: [String: Double] = [:]
        var out = Upstreams()
        for part in parts {
            out.forwardedQueries += part.forwardedQueries
            out.totalQueries += part.totalQueries
            for server in part.upstreams {
                let key = "\(server.ip):\(server.port)"
                var entry =
                    byKey[key]
                    ?? {
                        order.append(key)
                        var fresh = UpstreamServer()
                        fresh.ip = server.ip
                        fresh.port = server.port
                        return fresh
                    }()
                if entry.name.isEmpty {
                    entry.name = server.name
                }
                entry.count += server.count
                byKey[key] = entry
                let weight = Double(server.count)
                responseSum[key, default: 0] += server.responseTime * weight
                varianceSum[key, default: 0] += server.variance * weight
            }
        }
        out.upstreams = order.compactMap { key in
            guard var entry = byKey[key] else {
                return nil
            }
            if entry.count > 0 {
                entry.responseTime =
                    responseSum[key, default: 0]
                    / Double(entry.count)
                entry.variance =
                    varianceSum[key, default: 0]
                    / Double(entry.count)
            }
            return entry
        }
        .sorted { lhs, rhs in
            lhs.count != rhs.count
                ? lhs.count > rhs.count
                : "\(lhs.ip):\(lhs.port)" < "\(rhs.ip):\(rhs.port)"
        }
        return out
    }

    static func topDomains(_ parts: [TopDomains], count: Int) -> TopDomains {
        var counts: [String: Int] = [:]
        var out = TopDomains()
        for part in parts {
            out.totalQueries += part.totalQueries
            out.blockedQueries += part.blockedQueries
            for entry in part.domains {
                counts[entry.domain, default: 0] += entry.count
            }
        }
        out.domains = ranked(counts, count: count).map { domain, total in
            var entry = TopDomains.Entry()
            entry.domain = domain
            entry.count = total
            return entry
        }
        return out
    }

    static func topClients(_ parts: [TopClients], count: Int) -> TopClients {
        var counts: [String: Int] = [:]
        var names: [String: String] = [:]
        var out = TopClients()
        for part in parts {
            out.totalQueries += part.totalQueries
            out.blockedQueries += part.blockedQueries
            for entry in part.clients {
                counts[entry.ip, default: 0] += entry.count
                if names[entry.ip, default: ""].isEmpty {
                    names[entry.ip] = entry.name
                }
            }
        }
        out.clients = ranked(counts, count: count).map { ip, total in
            var entry = TopClients.Entry()
            entry.ip = ip
            entry.name = names[ip, default: ""]
            entry.count = total
            return entry
        }
        return out
    }

    /// Highest count first, ties by key, trimmed to `count` (all when <= 0).
    private static func ranked(_ counts: [String: Int], count: Int)
        -> [(String, Int)]
    {
        let sorted = counts.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
        }
        .map { ($0.key, $0.value) }
        return count > 0 ? Array(sorted.prefix(count)) : sorted
    }

    static func queries(
        _ parts: [(name: String, value: QueriesPage)], length: Int?
    ) -> QueriesPage {
        var out = QueriesPage()
        var rows: [DNSQuery] = []
        for (name, page) in parts {
            out.recordsFiltered += page.recordsFiltered
            out.recordsTotal += page.recordsTotal
            rows += page.queries.map { query in
                var tagged = query
                tagged.instance = name
                return tagged
            }
        }
        rows.sort { $0.time > $1.time }
        if let length, length > 0 {
            rows = Array(rows.prefix(length))
        }
        out.queries = rows
        return out
    }
}

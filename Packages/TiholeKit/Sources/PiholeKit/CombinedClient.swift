import Foundation

/// A merged read result plus the members that could not contribute to it.
public struct Combined<Value: Sendable>: Sendable {
    public var value: Value
    /// Names of the members that failed or are cooling down, sorted. Empty
    /// when every member answered.
    public var failed: [String]

    public init(value: Value, failed: [String] = []) {
        self.value = value
        self.failed = failed
    }
}

/// Every configured Pi-hole read as one network. People run several Pi-holes
/// for redundancy, so each one sees only part of the traffic.
///
/// It offers the reads the dashboard and query log use, plus blocking on/off,
/// which only means something network-wide when it spans every member. Other
/// writes go to the active instance's client. Mirrors tihole's `pihole.Group`.
public final class CombinedClient: @unchecked Sendable {
    public struct Member: Sendable {
        public let name: String
        public let client: PiholeClient

        public init(name: String, client: PiholeClient) {
            self.name = name
            self.client = client
        }
    }

    /// How long one member may take before it counts as unreachable.
    static let memberTimeout = 2.0
    /// How long a failed member is skipped before reads retry it, so one
    /// blackholed Pi-hole costs a 2s lag every 30s, not on every poll.
    static let memberCooldown = 30.0

    public let members: [Member]
    /// Instances that could not be built (no password, bad URL). They count
    /// as failed on every call.
    public let unavailable: [String]

    /// Clock, swappable in tests.
    let now: @Sendable () -> Date
    private let lock = NSLock()
    /// When each member last failed; absent once it answers again.
    private var down: [String: Date] = [:]

    public convenience init(members: [Member], unavailable: [String] = []) {
        self.init(members: members, unavailable: unavailable, now: Date.init)
    }

    init(
        members: [Member], unavailable: [String],
        now: @escaping @Sendable () -> Date
    ) {
        self.members = members
        self.unavailable = unavailable
        self.now = now
    }

    private func coolingDown(_ name: String) -> Bool {
        lock.withLock {
            guard let since = down[name] else {
                return false
            }
            return now().timeIntervalSince(since) < Self.memberCooldown
        }
    }

    private func record(_ name: String, failed: Bool) {
        lock.withLock {
            down[name] = failed ? now() : nil
        }
    }

    /// Runs `operation` on every member concurrently, each under its own
    /// deadline. Reads skip members in cooldown; writes (`skipDown` false)
    /// always try every member. Returns successes in member order, every
    /// member's error, and the sorted names of the members left out.
    func fanOut<T: Sendable>(
        skipDown: Bool = true,
        _ operation: @escaping @Sendable (PiholeClient) async throws -> T
    ) async throws -> (
        results: [(name: String, value: T)],
        errors: [(name: String, error: Error)],
        failed: [String]
    ) {
        let live = members.filter { !skipDown || !coolingDown($0.name) }
        let outcomes = await withTaskGroup(
            of: (Int, Result<T, Error>).self
        ) { group in
            for (index, member) in live.enumerated() {
                group.addTask {
                    do {
                        return (
                            index,
                            .success(
                                try await Self.withDeadline {
                                    try await operation(member.client)
                                })
                        )
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var collected = [Result<T, Error>?](
                repeating: nil, count: live.count)
            for await (index, result) in group {
                collected[index] = result
            }
            return collected
        }
        // The caller gave up: that says nothing about the members.
        try Task.checkCancellation()

        var results: [(name: String, value: T)] = []
        var errors: [(name: String, error: Error)] = []
        for (member, outcome) in zip(live, outcomes) {
            switch outcome {
            case .success(let value):
                record(member.name, failed: false)
                results.append((member.name, value))
            case .failure(let error):
                record(member.name, failed: true)
                errors.append((member.name, error))
            case nil:
                record(member.name, failed: true)
                errors.append((member.name, CancellationError()))
            }
        }
        let answered = Set(results.map(\.name))
        let failed = (members.map(\.name) + unavailable)
            .filter { !answered.contains($0) }
            .sorted()
        return (results, errors, failed)
    }

    /// `operation`, or a timeout error once `seconds` pass. It returns at the
    /// deadline even if `operation` ignores cancellation, which a task group
    /// would wait out.
    static func withDeadline<T: Sendable>(
        seconds: Double = memberTimeout,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let once = Once<T>()
        let work = Task {
            once.finish(await Result(catching: operation))
        }
        let timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            once.finish(
                .failure(
                    PiholeError.network(
                        operation: "combined", underlying: URLError(.timedOut)
                    )))
        }
        defer {
            work.cancel()
            timer.cancel()
        }
        return try await withTaskCancellationHandler {
            try await once.value()
        } onCancel: {
            once.finish(.failure(CancellationError()))
        }
    }

    private func merged<T: Sendable, U: Sendable>(
        _ operation: @escaping @Sendable (PiholeClient) async throws -> T,
        _ merge: ([(name: String, value: T)]) -> U
    ) async throws -> Combined<U> {
        let (results, errors, failed) = try await fanOut(operation)
        if results.isEmpty {
            throw errors.first?.error
                ?? PiholeError.network(
                    operation: "combined",
                    underlying: URLError(.cannotConnectToHost))
        }
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

    /// Blocking across every member: `isBlocking` only when all of them
    /// block, with `on` of `total` answering members blocking.
    public func blocking() async throws -> Combined<BlockingStatus> {
        try await merged({ try await $0.blocking() }) {
            Merge.blocking($0.map(\.value))
        }
    }

    /// Turns blocking on or off on every member, cooldown or not, since this
    /// is an explicit action. Throws naming each member that was not changed,
    /// even when the others were.
    public func setBlocking(_ blocking: Bool, timer: Double? = nil)
        async throws
    {
        let (_, errors, _) = try await fanOut(skipDown: false) {
            try await $0.setBlocking(blocking, timer: timer)
        }
        guard errors.isEmpty else {
            throw CombinedWriteError(failures: errors)
        }
    }
}

/// A result that is delivered once; later deliveries are dropped.
private final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var waiter: CheckedContinuation<T, Error>?

    func finish(_ outcome: Result<T, Error>) {
        let resume: CheckedContinuation<T, Error>? = lock.withLock {
            guard result == nil else {
                return nil
            }
            result = outcome
            defer { waiter = nil }
            return waiter
        }
        resume?.resume(with: outcome)
    }

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<T, Error>? = lock.withLock {
                if result == nil {
                    waiter = continuation
                }
                return result
            }
            if let ready {
                continuation.resume(with: ready)
            }
        }
    }
}

extension Result where Failure == Error {
    fileprivate init(catching body: () async throws -> Success) async {
        do {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }
}

/// A combined write that some members did not apply.
public struct CombinedWriteError: LocalizedError {
    public let failures: [(name: String, error: Error)]

    public var errorDescription: String? {
        failures.map { name, error in
            let reason =
                (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return "blocking not changed on \(name): \(reason)"
        }
        .joined(separator: "\n")
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

    static func blocking(_ parts: [BlockingStatus]) -> BlockingStatus {
        var out = BlockingStatus()
        out.total = parts.count
        out.on = parts.filter(\.isBlocking).count
        out.isBlocking = out.on == out.total
        out.status = out.isBlocking ? "enabled" : "disabled"
        // The soonest re-enable among the members that are off.
        out.timer = parts.filter { !$0.isBlocking }
            .compactMap(\.timer)
            .filter { $0 > 0 }
            .min()
        return out
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

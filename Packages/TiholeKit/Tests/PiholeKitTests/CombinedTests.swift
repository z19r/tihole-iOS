import Foundation
import XCTest

@testable import PiholeKit

final class MergeTests: XCTestCase {
    private func summary(
        total: Int, blocked: Int, unique: Int, active: Int, gravity: Int,
        updated: Int
    ) -> Summary {
        var out = Summary()
        out.queries.total = total
        out.queries.blocked = blocked
        out.queries.uniqueDomains = unique
        out.queries.percentBlocked = 99  // must be recomputed, not averaged
        out.clients.active = active
        out.clients.total = active
        out.gravity.domainsBeingBlocked = gravity
        out.gravity.lastUpdate = updated
        return out
    }

    func testSummarySumsCountsAndRecomputesRatio() {
        let merged = Merge.summary([
            summary(
                total: 300, blocked: 30, unique: 50, active: 4, gravity: 100,
                updated: 20),
            summary(
                total: 100, blocked: 70, unique: 80, active: 6, gravity: 100,
                updated: 10),
        ])
        XCTAssertEqual(merged.queries.total, 400)
        XCTAssertEqual(merged.queries.blocked, 100)
        XCTAssertEqual(merged.queries.percentBlocked, 25, accuracy: 0.0001)
        XCTAssertEqual(merged.queries.uniqueDomains, 80)
        XCTAssertEqual(merged.clients.active, 6)
        XCTAssertEqual(merged.gravity.domainsBeingBlocked, 100)
        XCTAssertEqual(merged.gravity.lastUpdate, 10)
        XCTAssertFalse(merged.gravityMismatch)
    }

    func testSummaryFlagsGravityMismatchAndZeroTotal() {
        let merged = Merge.summary([
            summary(
                total: 0, blocked: 0, unique: 0, active: 0, gravity: 100,
                updated: 1),
            summary(
                total: 0, blocked: 0, unique: 0, active: 0, gravity: 120,
                updated: 1),
        ])
        XCTAssertEqual(merged.queries.percentBlocked, 0)
        XCTAssertEqual(merged.gravity.domainsBeingBlocked, 120)
        XCTAssertTrue(merged.gravityMismatch)
    }

    func testHistoryAlignsByTimestamp() {
        func history(_ points: [(Int, Int)]) -> QueryHistory {
            var out = QueryHistory()
            out.history = points.map { timestamp, total in
                var point = HistoryPoint()
                point.timestamp = timestamp
                point.total = total
                point.blocked = 1
                return point
            }
            return out
        }
        let merged = Merge.history([
            history([(20, 5), (10, 1)]), history([(10, 2), (30, 7)]),
        ])
        XCTAssertEqual(merged.history.map(\.timestamp), [10, 20, 30])
        XCTAssertEqual(merged.history.map(\.total), [3, 5, 7])
        XCTAssertEqual(merged.history.map(\.blocked), [2, 1, 1])
    }

    func testQueryTypesSumPerKey() {
        var a = QueryTypes()
        a.types = ["A": 1, "AAAA": 2]
        var b = QueryTypes()
        b.types = ["A": 3, "MX": 1]
        XCTAssertEqual(
            Merge.queryTypes([a, b]).types, ["A": 4, "AAAA": 2, "MX": 1])
    }

    func testUpstreamsWeightByCount() {
        func upstreams(_ count: Int, _ response: Double, name: String)
            -> Upstreams
        {
            var server = UpstreamServer()
            server.ip = "1.1.1.1"
            server.port = 53
            server.name = name
            server.count = count
            server.responseTime = response
            server.variance = response
            var out = Upstreams()
            out.upstreams = [server]
            out.forwardedQueries = count
            out.totalQueries = count * 2
            return out
        }
        let merged = Merge.upstreams([
            upstreams(1, 10, name: ""), upstreams(3, 2, name: "one.one"),
        ])
        XCTAssertEqual(merged.upstreams.count, 1)
        XCTAssertEqual(merged.upstreams[0].count, 4)
        XCTAssertEqual(merged.upstreams[0].name, "one.one")
        XCTAssertEqual(merged.upstreams[0].responseTime, 4, accuracy: 0.0001)
        XCTAssertEqual(merged.upstreams[0].variance, 4, accuracy: 0.0001)
        XCTAssertEqual(merged.forwardedQueries, 4)
        XCTAssertEqual(merged.totalQueries, 8)
    }

    func testTopDomainsSumRankAndTrim() {
        func top(_ entries: [(String, Int)]) -> TopDomains {
            var out = TopDomains()
            out.totalQueries = 10
            out.domains = entries.map { domain, count in
                var entry = TopDomains.Entry()
                entry.domain = domain
                entry.count = count
                return entry
            }
            return out
        }
        let merged = Merge.topDomains(
            [top([("a", 5), ("b", 4)]), top([("b", 2), ("c", 6)])], count: 2)
        XCTAssertEqual(merged.domains.map(\.domain), ["b", "c"])
        XCTAssertEqual(merged.domains.map(\.count), [6, 6])
        XCTAssertEqual(merged.totalQueries, 20)
    }

    func testTopClientsKeepFirstName() {
        func top(_ ip: String, _ name: String, _ count: Int) -> TopClients {
            var entry = TopClients.Entry()
            entry.ip = ip
            entry.name = name
            entry.count = count
            var out = TopClients()
            out.clients = [entry]
            return out
        }
        let merged = Merge.topClients(
            [top("10.0.0.2", "", 1), top("10.0.0.2", "laptop", 2)], count: 5)
        XCTAssertEqual(merged.clients.first?.name, "laptop")
        XCTAssertEqual(merged.clients.first?.count, 3)
    }

    func testQueriesMergeNewestFirstAndTag() {
        func page(_ times: [Double]) -> QueriesPage {
            var out = QueriesPage()
            out.recordsTotal = 100
            out.recordsFiltered = 50
            out.cursor = 9
            out.queries = times.map { time in
                var query = DNSQuery()
                query.time = time
                return query
            }
            return out
        }
        let merged = Merge.queries(
            [("pi1", page([5, 3, 1])), ("pi2", page([4, 2]))], length: 3)
        XCTAssertEqual(merged.queries.map(\.time), [5, 4, 3])
        XCTAssertEqual(merged.queries.map(\.instance), ["pi1", "pi2", "pi1"])
        XCTAssertEqual(merged.recordsTotal, 200)
        XCTAssertEqual(merged.recordsFiltered, 100)
        XCTAssertNil(merged.cursor)
    }
}

final class CombinedClientTests: MockFTLTestCase {
    private func member(_ host: String) -> CombinedClient.Member {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return CombinedClient.Member(
            name: host,
            client: PiholeClient(
                baseURL: "http://\(host).test", password: "pw",
                session: URLSession(configuration: configuration)))
    }

    private func serve(down: Set<String>) {
        MockURLProtocol.handler = { request in
            let name = String(request.host.prefix { $0 != "." })
            if down.contains(name) {
                throw URLError(.cannotConnectToHost)
            }
            if request.rawPath == "/api/auth" {
                return .authOK("S")
            }
            return .json(200, #"{"queries":{"total":10,"blocked":5}}"#)
        }
    }

    func testOneMemberDownStillMerges() async throws {
        serve(down: ["b"])
        let combined = CombinedClient(
            members: [member("a"), member("b"), member("c")],
            unavailable: ["d"])

        let result = try await combined.summary()

        XCTAssertEqual(result.value.queries.total, 20)
        XCTAssertEqual(result.value.queries.percentBlocked, 50, accuracy: 0.01)
        XCTAssertEqual(result.failed, ["b", "d"])
    }

    func testEveryMemberDownThrows() async {
        serve(down: ["a", "b"])
        let combined = CombinedClient(members: [member("a"), member("b")])
        do {
            _ = try await combined.summary()
            XCTFail("expected an error")
        } catch {}
    }
}

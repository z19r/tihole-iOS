import Foundation
import XCTest

@testable import PiholeKit

final class BlockingTests: MockFTLTestCase {
    func testStatusStringBecomesBoolean() async throws {
        // FTL v6 reports the state as a status string on GET, not a boolean.
        let client = await makeAuthedClient(
            .json(200, #"{"blocking":"disabled","timer":42,"took":0.0}"#))

        let status = try await client.blocking()

        XCTAssertFalse(status.isBlocking)
        XCTAssertEqual(status.status, "disabled")
        XCTAssertEqual(status.timer, 42)
        XCTAssertEqual(log.last?.rawPath, "/api/dns/blocking")
    }

    func testNullTimer() async throws {
        let client = await makeAuthedClient(
            .json(200, #"{"blocking":"enabled","timer":null,"took":0.0}"#))

        let status = try await client.blocking()

        XCTAssertTrue(status.isBlocking)
        XCTAssertNil(status.timer)
    }

    func testSetBlockingWithTimer() async throws {
        let client = await makeAuthedClient(
            .json(200, #"{"blocking":"disabled","timer":300}"#))

        try await client.setBlocking(false, timer: 300)

        let request = try XCTUnwrap(log.last)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.rawPath, "/api/dns/blocking")
        XCTAssertEqual(request.json["blocking"] as? Bool, false)
        XCTAssertEqual(request.json["timer"] as? Double, 300)
    }

    func testSetBlockingSendsExplicitNullTimer() async throws {
        let client = await makeAuthedClient(
            .json(200, #"{"blocking":"enabled","timer":null}"#))

        try await client.setBlocking(true)

        let request = try XCTUnwrap(log.last)
        XCTAssertEqual(request.json["blocking"] as? Bool, true)
        XCTAssertTrue(request.json["timer"] is NSNull)
    }
}

final class StatsTests: MockFTLTestCase {
    func testSummaryDecodes() async throws {
        let client = await makeAuthedClient(
            .json(
                200,
                """
                {
                  "queries": {"total": 12345, "blocked": 2345,
                   "percent_blocked": 18.99,
                              "unique_domains": 800, "forwarded": 6000,
                               "cached": 4000, "frequency": 1.5},
                  "clients": {"active": 12, "total": 30},
                  "gravity": {"domains_being_blocked": 150000,
                   "last_update": 1700000000},
                  "took": 0.002
                }
                """))

        let summary = try await client.summary()

        XCTAssertEqual(summary.queries.total, 12345)
        XCTAssertEqual(summary.queries.blocked, 2345)
        XCTAssertEqual(summary.queries.percentBlocked, 18.99, accuracy: 0.0001)
        XCTAssertEqual(summary.clients.active, 12)
        XCTAssertEqual(summary.gravity.domainsBeingBlocked, 150000)
    }

    func testMissingKeysFallBackToZero() async throws {
        let client = await makeAuthedClient(
            .json(200, #"{"queries":{"total":5},"took":0}"#))

        let summary = try await client.summary()

        XCTAssertEqual(summary.queries.total, 5)
        XCTAssertEqual(summary.queries.blocked, 0)
        XCTAssertEqual(summary.clients.active, 0)
    }

    func testTopDomainsQuery() async throws {
        let client = await makeAuthedClient(
            .json(
                200,
                #"""
                {"domains":[{"domain":"a.example","count":9}],
                 "total_queries":10,"blocked_queries":1}
                """#
            )
        )

        let top = try await client.topDomains(blocked: true, count: 8)

        XCTAssertEqual(top.domains.first?.domain, "a.example")
        XCTAssertEqual(top.domains.first?.count, 9)
        XCTAssertEqual(log.last?.rawPath, "/api/stats/top_domains")
        XCTAssertEqual(log.last?.rawQuery, "blocked=true&count=8")
    }

    func testTopClientsOmitsNonPositiveCount() async throws {
        let client = await makeAuthedClient(
            .json(
                200, #"{"clients":[{"ip":"10.0.0.2","name":null,"count":3}]}"#))

        let top = try await client.topClients(blocked: false)

        XCTAssertEqual(top.clients.first?.ip, "10.0.0.2")
        XCTAssertEqual(top.clients.first?.name, "")
        XCTAssertEqual(log.last?.rawQuery, "blocked=false")
    }

    func testUpstreamStatisticsAreFlattened() async throws {
        let client = await makeAuthedClient(
            .json(
                200,
                """
                {"upstreams":[{"ip":"1.1.1.1","name":"one.one.one.one",
                 "port":53,"count":40,
                               "statistics":{"response":0.012,
                                "variance":0.001}}],
                 "forwarded_queries":40,"total_queries":100}
                """))

        let upstreams = try await client.upstreams()

        XCTAssertEqual(
            upstreams.upstreams.first?.responseTime ?? 0, 0.012,
            accuracy: 0.0001)
        XCTAssertEqual(upstreams.totalQueries, 100)
    }

    func testHistoryDecodes() async throws {
        let client = await makeAuthedClient(
            .json(
                200,
                #"""
                {"history":[{"timestamp":1700000000,"total":10,"cached":2,
                 "blocked":3,"forwarded":5}]}
                """#
            )
        )

        let history = try await client.history()

        XCTAssertEqual(
            history.history,
            [
                HistoryPoint(
                    timestamp: 1_700_000_000, total: 10, cached: 2, blocked: 3,
                    forwarded: 5)
            ])
    }

    func testSystemReadsPercentKeys() async throws {
        let client = await makeAuthedClient(
            .json(
                200,
                """
                {"system":{"uptime":90061,"procs":120,
                  "memory":{"ram":{"total":4000000,"used":1000000,"%used":25.0},
                   "swap":{"%used":1.5}},
                  "cpu":{"nprocs":4,"%cpu":12.5,"load":{"raw":[0.5,0.4,0.3],
                   "percent":[12.0,10.0,8.0]}},
                  "ftl":{"%mem":0.8,"%cpu":0.2}},"took":0}
                """))

        let system = try await client.system()

        XCTAssertEqual(system.uptime, 90061)
        XCTAssertEqual(system.procs, 120)
        XCTAssertEqual(system.nprocs, 4)
        XCTAssertEqual(system.cpuPercent, 12.5)
        XCTAssertEqual(system.load1Percent, 12.0)
        XCTAssertEqual(system.memUsedPercent, 25.0)
        XCTAssertEqual(system.memTotalKiB, 4_000_000)
        XCTAssertEqual(system.swapUsedPercent, 1.5)
        XCTAssertEqual(system.ftlMemPercent, 0.8)
        XCTAssertEqual(system.ftlCPUPercent, 0.2)
    }

    func testSensorsWithoutTemperature() async throws {
        let client = await makeAuthedClient(
            .json(
                200, #"{"sensors":{"cpu_temp":null,"hot_limit":60,"unit":"C"}}"#
            ))

        let sensors = try await client.sensors()

        XCTAssertFalse(sensors.hasTemp)
        XCTAssertEqual(sensors.hotLimit, 60)
        XCTAssertEqual(sensors.unit, "C")
    }

    func testSensorsWithTemperature() async throws {
        let client = await makeAuthedClient(
            .json(
                200, #"{"sensors":{"cpu_temp":48.3,"hot_limit":60,"unit":"C"}}"#
            ))

        let sensors = try await client.sensors()

        XCTAssertEqual(
            sensors,
            Sensors(hasTemp: true, cpuTemp: 48.3, hotLimit: 60, unit: "C"))
    }
}

final class QueriesTests: MockFTLTestCase {
    func testFilterSendsOnlySetFields() async throws {
        let client = await makeAuthedClient(.json(200, #"{"queries":[]}"#))

        _ = try await client.queries(
            QueryFilter(
                length: 100, cursor: 55, domain: "ads.example.com", disk: true))

        XCTAssertEqual(
            log.last?.rawQuery,
            "cursor=55&disk=true&domain=ads.example.com&length=100")
    }

    func testEmptyFilterSendsNoQuery() async throws {
        let client = await makeAuthedClient(.json(200, #"{"queries":[]}"#))

        _ = try await client.queries()

        XCTAssertEqual(log.last?.rawPath, "/api/queries")
        XCTAssertEqual(log.last?.rawQuery, "")
    }

    func testPageDecodes() async throws {
        let client = await makeAuthedClient(
            .json(
                200,
                """
                {"queries":[{"id":7,"time":1700000000.25,"type":"A",
                 "domain":"ads.example.com","cname":null,
                             "status":"GRAVITY","client":{"ip":"10.0.0.5",
                              "name":"laptop"},"dnssec":"UNKNOWN",
                             "reply":{"type":"NODATA","time":0.0004},
                              "list_id":3,"upstream":null}],
                 "cursor":7,"recordsFiltered":1,"recordsTotal":900,
                  "draft_cursor":null}
                """))

        let page = try await client.queries()

        let query = try XCTUnwrap(page.queries.first)
        XCTAssertEqual(query.id, 7)
        XCTAssertEqual(query.domain, "ads.example.com")
        XCTAssertEqual(query.cname, "")
        XCTAssertEqual(query.status, "GRAVITY")
        XCTAssertEqual(
            query.client, DNSQuery.Client(ip: "10.0.0.5", name: "laptop"))
        XCTAssertEqual(query.reply.type, "NODATA")
        XCTAssertEqual(query.listID, 3)
        XCTAssertEqual(query.upstream, "")
        XCTAssertEqual(page.cursor, 7)
        XCTAssertNil(page.draftCursor)
        XCTAssertEqual(page.recordsTotal, 900)
    }
}

final class DomainsTests: MockFTLTestCase {
    func testListDecodesNullComment() async throws {
        let client = await makeAuthedClient(
            .json(
                200,
                """
                {"domains":[{"domain":"xn--bcher-kva.example",
                 "unicode":"bücher.example","type":"deny","kind":"exact",
                             "comment":null,"groups":[0,2],"enabled":true,
                              "id":4,"date_added":1,"date_modified":2}]}
                """))

        let domains = try await client.domains()

        let domain = try XCTUnwrap(domains.first)
        XCTAssertEqual(domain.comment, "")
        XCTAssertEqual(domain.groups, [0, 2])
        XCTAssertEqual(domain.domainType, .deny)
        XCTAssertEqual(domain.domainKind, .exact)
        XCTAssertEqual(domain.displayName, "bücher.example")
    }

    func testAddPostsItemInBody() async throws {
        let client = await makeAuthedClient(
            .json(201, #"{"domains":[{"domain":"ads.example.com","id":9}]}"#))

        let created = try await client.addDomain(
            type: .deny,
            kind: .exact,
            domain: "ads.example.com",
            comment: "noisy",
            groups: [0]
        )

        XCTAssertEqual(created.id, 9)
        let request = try XCTUnwrap(log.last)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.rawPath, "/api/domains/deny/exact")
        XCTAssertEqual(request.json["domain"] as? String, "ads.example.com")
        XCTAssertEqual(request.json["comment"] as? String, "noisy")
        XCTAssertEqual(request.json["groups"] as? [Int], [0])
        XCTAssertEqual(request.json["enabled"] as? Bool, true)
    }

    func testAddWithoutGroupsOmitsKey() async throws {
        let client = await makeAuthedClient(.json(201, #"{"domains":[]}"#))

        try await client.addDomain(
            type: .allow, kind: .exact, domain: "ok.example.com")

        XCTAssertNil(log.last?.json["groups"])
    }

    func testRegexDomainIsOnePathSegment() async throws {
        let client = await makeAuthedClient(.json(200, #"{"domains":[]}"#))

        try await client.updateDomain(
            type: .deny,
            kind: .regex,
            domain: #"^ads?\.(foo|bar)/x$"#,
            comment: "",
            groups: [0],
            enabled: false
        )

        let request = try XCTUnwrap(log.last)
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(
            request.rawPath,
            "/api/domains/deny/regex/%5Eads%3F%5C.%28foo%7Cbar%29%2Fx$")
        XCTAssertEqual(request.json["enabled"] as? Bool, false)
        XCTAssertNil(request.json["domain"])
    }

    func testDeletePath() async throws {
        let client = await makeAuthedClient(.empty(204))

        try await client.deleteDomain(
            type: .allow, kind: .exact, domain: "ok.example.com")

        XCTAssertEqual(log.last?.method, "DELETE")
        XCTAssertEqual(
            log.last?.rawPath, "/api/domains/allow/exact/ok.example.com")
    }
}

final class GroupsClientsListsTests: MockFTLTestCase {
    func testUpdateGroupEscapesName() async throws {
        let client = await makeAuthedClient(
            .json(200, #"{"groups":[{"name":"kids room","enabled":false}]}"#))

        let group = try await client.updateGroup(
            name: "kids room", comment: "tablets", enabled: false)

        XCTAssertEqual(group.name, "kids room")
        XCTAssertEqual(log.last?.rawPath, "/api/groups/kids%20room")
        XCTAssertEqual(log.last?.json["comment"] as? String, "tablets")
        XCTAssertNil(log.last?.json["name"])
    }

    func testAddGroupBody() async throws {
        let client = await makeAuthedClient(
            .json(201, #"{"groups":[{"name":"iot","id":3}]}"#))

        let group = try await client.addGroup(name: "iot", comment: "")

        XCTAssertEqual(group.id, 3)
        XCTAssertEqual(log.last?.json["name"] as? String, "iot")
        XCTAssertEqual(log.last?.json["enabled"] as? Bool, true)
    }

    func testClientSubnetIsOnePathSegment() async throws {
        let client = await makeAuthedClient(.empty(204))

        try await client.deleteClient(client: "192.168.1.0/24")

        XCTAssertEqual(log.last?.rawPath, "/api/clients/192.168.1.0%2F24")
    }

    func testSuggestionsDecode() async throws {
        let client = await makeAuthedClient(
            .json(
                200,
                """
                {"clients":[{"hwaddr":"aa:bb:cc:dd:ee:ff","macVendor":"Acme",
                 "lastQuery":1700000000,
                             "name":"tv","addresses":"10.0.0.9,10.0.0.10"}]}
                """))

        let suggestions = try await client.clientSuggestions()

        XCTAssertEqual(suggestions.first?.macVendor, "Acme")
        XCTAssertEqual(suggestions.first?.addresses, "10.0.0.9,10.0.0.10")
        XCTAssertEqual(log.last?.rawPath, "/api/clients/_suggestions")
    }

    func testListsQuery() async throws {
        let client = await makeAuthedClient(
            .json(
                200,
                """
                {"lists":[{"address":"https://example.com/hosts.txt",
                 "type":"block","comment":null,"groups":[0],
                           "enabled":true,"id":1,"number":1234,
                            "invalid_domains":2,"status":1}]}
                """))

        let lists = try await client.lists(type: .block)

        XCTAssertEqual(lists.first?.number, 1234)
        XCTAssertEqual(lists.first?.listType, .block)
        XCTAssertEqual(log.last?.rawPath, "/api/lists")
        XCTAssertEqual(log.last?.rawQuery, "type=block")
    }

    func testUpdateListEscapesAddress() async throws {
        let client = await makeAuthedClient(.json(200, #"{"lists":[]}"#))

        try await client.updateList(
            address: "https://example.com/hosts.txt?v=1",
            type: .allow,
            comment: "c",
            groups: [0, 1],
            enabled: true
        )

        let request = try XCTUnwrap(log.last)
        XCTAssertEqual(
            request.rawPath,
            "/api/lists/https:%2F%2Fexample.com%2Fhosts.txt%3Fv=1")
        XCTAssertEqual(request.rawQuery, "type=allow")
        XCTAssertEqual(request.json["type"] as? String, "allow")
        XCTAssertEqual(request.json["groups"] as? [Int], [0, 1])
    }
}

final class ConfigTests: MockFTLTestCase {
    func testConfigTreeAndDetailedParam() async throws {
        let client = await makeAuthedClient(
            .json(
                200, #"{"config":{"dns":{"upstreams":["1.1.1.1"]}},"took":0}"#))

        let tree = try await client.config(detailed: true)

        XCTAssertEqual(
            tree.value(atPath: "dns.upstreams"), .array([.string("1.1.1.1")]))
        XCTAssertEqual(log.last?.rawPath, "/api/config")
        XCTAssertEqual(log.last?.rawQuery, "detailed=true")
    }

    func testElementPathUsesSlashes() async throws {
        let client = await makeAuthedClient(
            .json(200, #"{"config":{"dns":{"upstreams":[]}}}"#))

        _ = try await client.configElement("dns.upstreams")

        XCTAssertEqual(log.last?.rawPath, "/api/config/dns/upstreams")
    }

    func testPatchBodyAndRestartParam() async throws {
        let client = await makeAuthedClient(.json(200, #"{"config":{}}"#))

        try await client.patchConfig(
            .object(["misc": .object(["temp": .object(["limit": .number(85)])])]
            ),
            restart: false
        )

        let request = try XCTUnwrap(log.last)
        XCTAssertEqual(request.method, "PATCH")
        XCTAssertEqual(request.rawQuery, "restart=false")
        XCTAssertEqual(
            String(decoding: request.body, as: UTF8.self),
            #"{"config":{"misc":{"temp":{"limit":85}}}}"#
        )
    }

    func testHostRecordIsOnePathSegment() async throws {
        let client = await makeAuthedClient(.empty(204))

        try await client.addHostRecord(ip: "192.168.1.5", domain: "nas.lan")

        XCTAssertEqual(log.last?.method, "PUT")
        XCTAssertEqual(
            log.last?.rawPath, "/api/config/dns/hosts/192.168.1.5%20nas.lan")
    }

    func testDeleteHostRecordPath() async throws {
        let client = await makeAuthedClient(.empty(204))

        try await client.deleteHostRecord(
            HostRecord(ip: "fd00::5", domain: "nas.lan"))

        XCTAssertEqual(log.last?.method, "DELETE")
        XCTAssertEqual(
            log.last?.rawPath, "/api/config/dns/hosts/fd00::5%20nas.lan")
    }

    func testDeleteSendsStoredStringUnchanged() async throws {
        let client = await makeAuthedClient(.empty(204))

        try await client.deleteHostRecord(
            HostRecord(configValue: "10.0.0.5\tnas"))
        XCTAssertEqual(
            log.last?.rawPath, "/api/config/dns/hosts/10.0.0.5%09nas")

        try await client.deleteCNAMERecord(
            CNAMERecord(configValue: "a.lan, b.lan"))
        XCTAssertEqual(
            log.last?.rawPath, "/api/config/dns/cnameRecords/a.lan%2C%20b.lan")
    }

    func testHostRecordsParse() async throws {
        let client = await makeAuthedClient(
            .json(
                200,
                #"""
                {"config":{"dns":{"hosts":["192.168.1.5 nas.lan",
                 "10.0.0.1   router.lan alias", 7]}}}
                """#
            )
        )

        let records = try await client.hostRecords()

        XCTAssertEqual(records.map(\.ip), ["192.168.1.5", "10.0.0.1"])
        XCTAssertEqual(records.map(\.domain), ["nas.lan", "router.lan alias"])
        XCTAssertEqual(records.last?.configValue, "10.0.0.1   router.lan alias")
    }

    func testCNAMERecordsParse() async throws {
        let client = await makeAuthedClient(
            .json(
                200,
                #"""
                {"config":{"dns":{"cnameRecords":["a.lan,b.lan",
                 "c.lan,d.lan,300","e.lan,f.lan,oops"]}}}
                """#
            )
        )

        let records = try await client.cnameRecords()

        XCTAssertEqual(records.map(\.domain), ["a.lan", "c.lan", "e.lan"])
        XCTAssertEqual(records.map(\.target), ["b.lan", "d.lan", "f.lan"])
        XCTAssertEqual(records.map(\.ttl), [0, 300, 0])
    }

    func testCNAMEWithTTLPath() async throws {
        let client = await makeAuthedClient(.empty(204))

        try await client.addCNAMERecord(
            domain: "a.lan", target: "b.lan", ttl: 300)

        XCTAssertEqual(
            log.last?.rawPath,
            "/api/config/dns/cnameRecords/a.lan%2Cb.lan%2C300")
    }

    func testCNAMEOmitsNonPositiveTTL() async throws {
        let client = await makeAuthedClient(.empty(204))

        try await client.deleteCNAMERecord(
            CNAMERecord(domain: "a.lan", target: "b.lan", ttl: 0))

        XCTAssertEqual(log.last?.method, "DELETE")
        XCTAssertEqual(
            log.last?.rawPath, "/api/config/dns/cnameRecords/a.lan%2Cb.lan")
    }
}

final class InfoNetworkActionTests: MockFTLTestCase {
    func testInfoUnwrapsSection() async throws {
        let client = await makeAuthedClient(
            .json(
                200,
                #"""
                {"host":{"uname":{"sysname":"Linux"},"model":"Pi 4"},"took":0}
                """#
            ))

        let info = try await client.info("host")

        XCTAssertEqual(info["model"], .string("Pi 4"))
        XCTAssertEqual(log.last?.rawPath, "/api/info/host")
    }

    func testInfoWithoutSectionKeyDropsTook() async throws {
        let client = await makeAuthedClient(
            .json(200, #"{"version":"v6.1","took":0.5}"#))

        let info = try await client.info("ftl")

        XCTAssertEqual(info, .object(["version": .string("v6.1")]))
    }

    func testMessagesAndCount() async throws {
        let client = makeClient { request in
            if request.rawPath == "/api/info/messages/count" {
                return .json(200, #"{"count":2,"took":0}"#)
            }
            return .json(
                200,
                #"""
                {"messages":[{"id":1,"timestamp":1700000000,"type":"RATE_LIMIT",
                 "plain":"slow down","html":"<b>slow</b>","url":null}]}
                """#
            )
        }
        await client.setSessionID("S")

        let messages = try await client.messages()
        let count = try await client.messageCount()

        XCTAssertEqual(messages.first?.plain, "slow down")
        XCTAssertEqual(messages.first?.url, "")
        XCTAssertEqual(count, 2)
    }

    func testDeleteMessagesJoinsIDs() async throws {
        let client = await makeAuthedClient(.empty(204))

        try await client.deleteMessages(ids: [3, 5, 8])

        XCTAssertEqual(log.last?.method, "DELETE")
        XCTAssertEqual(log.last?.rawPath, "/api/info/messages/3,5,8")
    }

    func testDeleteMessagesEmptyIsNoop() async throws {
        let client = await makeAuthedClient(.empty(204))

        try await client.deleteMessages(ids: [])

        XCTAssertTrue(log.all.isEmpty)
    }

    func testDNSLogCursor() async throws {
        let client = await makeAuthedClient(
            .json(
                200,
                #"""
                {"log":[{"timestamp":1700000000.5,"message":"query[A] x",
                 "prio":null}],"nextID":42}
                """#
            )
        )

        let first = try await client.dnsLog()
        XCTAssertEqual(log.last?.rawQuery, "")
        XCTAssertEqual(first.nextID, 42)
        XCTAssertEqual(first.log.first?.message, "query[A] x")

        _ = try await client.dnsLog(nextID: 42)
        XCTAssertEqual(log.last?.rawQuery, "nextID=42")
    }

    func testNetworkDevices() async throws {
        let client = await makeAuthedClient(
            .json(
                200,
                """
                {"devices":[{"id":5,"hwaddr":"aa:bb:cc:dd:ee:ff",
                 "interface":"eth0","firstSeen":1,"lastQuery":2,
                             "numQueries":77,"macVendor":null,
                              "ips":[{"ip":"10.0.0.9","name":"tv",
                              "lastSeen":3}]}]}
                """))

        let devices = try await client.networkDevices()

        XCTAssertEqual(devices.first?.id, 5)
        XCTAssertEqual(devices.first?.macVendor, "")
        XCTAssertEqual(devices.first?.ips.first?.name, "tv")
    }

    func testDeleteNetworkDevicePath() async throws {
        let client = await makeAuthedClient(.empty(204))

        try await client.deleteNetworkDevice(id: 5)

        XCTAssertEqual(log.last?.rawPath, "/api/network/devices/5")
    }

    func testActionsPost() async throws {
        let client = await makeAuthedClient(
            .json(200, #"{"status":"success"}"#))

        try await client.restartDNS()
        try await client.flushLogs()
        try await client.flushNetwork()

        XCTAssertEqual(log.all.map(\.method), ["POST", "POST", "POST"])
        XCTAssertEqual(
            log.all.map(\.rawPath),
            [
                "/api/action/restartdns", "/api/action/flush/logs",
                "/api/action/flush/network",
            ]
        )
    }

    func testDestructiveActionSurfaces403() async throws {
        let client = await makeAuthedClient(
            .json(
                403,
                #"""
                {"error":{"key":"forbidden",
                 "message":"Destructive actions are disabled","hint":null}}
                """#
            )
        )

        do {
            try await client.restartDNS()
            XCTFail("expected an error")
        } catch let error as PiholeError {
            XCTAssertEqual(error.status, 403)
        }
    }
}

final class GravityTests: MockFTLTestCase {
    func testStreamsLines() async throws {
        let client = await makeAuthedClient(
            .text(
                200,
                """
                [i] Neutrino emissions detected\n[✓] Pulling blocklist\n[✓] \
                Done\n
                """
            ))

        var lines: [String] = []
        for try await line in client.updateGravity() {
            lines.append(line)
        }

        XCTAssertEqual(
            lines,
            [
                "[i] Neutrino emissions detected", "[✓] Pulling blocklist",
                "[✓] Done",
            ])
        let request = try XCTUnwrap(log.last)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.rawPath, "/api/action/gravity")
        XCTAssertEqual(request.sid, "S")
        XCTAssertEqual(request.headers["Accept"], "text/plain")
    }

    func testReauthenticatesOnce() async throws {
        let client = makeClient { request in
            if request.rawPath == "/api/auth" {
                return .authOK("FRESH")
            }
            return request.sid == "FRESH"
                ? .text(200, "ok\n") : .json(401, "{}")
        }

        var lines: [String] = []
        for try await line in client.updateGravity() {
            lines.append(line)
        }

        XCTAssertEqual(lines, ["ok"])
        XCTAssertEqual(log.count("POST", "/api/auth"), 1)
        XCTAssertEqual(log.count("POST", "/api/action/gravity"), 2)
    }

    func testErrorStatusThrowsAPIError() async throws {
        let client = await makeAuthedClient(
            .json(
                403,
                #"{"error":{"key":"forbidden","message":"No","hint":null}}"#)
        )

        do {
            for try await _ in client.updateGravity() {}
            XCTFail("expected an error")
        } catch let error as PiholeError {
            XCTAssertEqual(error.apiError?.status, 403)
            XCTAssertEqual(error.apiError?.message, "No")
        }
    }
}

final class EscapeTests: XCTestCase {
    func testSegmentMatchesGoPathEscape() {
        XCTAssertEqual(Escape.segment("plain-name_1.2~x"), "plain-name_1.2~x")
        XCTAssertEqual(Escape.segment("a b"), "a%20b")
        XCTAssertEqual(Escape.segment("a/b"), "a%2Fb")
        XCTAssertEqual(Escape.segment("a,b;c?d"), "a%2Cb%3Bc%3Fd")
        XCTAssertEqual(Escape.segment("$&+=:@"), "$&+=:@")
        XCTAssertEqual(Escape.segment("(a|b)*"), "%28a%7Cb%29%2A")
        XCTAssertEqual(Escape.segment("bücher"), "b%C3%BCcher")
    }

    func testElementJoinsWithSlashes() {
        XCTAssertEqual(Escape.element("dns.cnameRecords"), "dns/cnameRecords")
        XCTAssertEqual(
            Escape.element("webserver.api.allow_destructive"),
            "webserver/api/allow_destructive")
    }

    func testQueryStringIsSortedAndEscaped() {
        XCTAssertEqual(Escape.queryString([]), "")
        XCTAssertEqual(
            Escape.queryString([("b", "2"), ("a", "x y&z")]), "?a=x%20y%26z&b=2"
        )
    }
}

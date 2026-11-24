import Foundation
import PiholeKit
import XCTest

@testable import TiholeCore

final class FormatTests: XCTestCase {
    func testCount() {
        XCTAssertEqual(Format.count(0), "0")
        XCTAssertEqual(Format.count(999), "999")
        XCTAssertEqual(Format.count(1000), "1,000")
        XCTAssertEqual(Format.count(12345), "12,345")
        XCTAssertEqual(Format.count(1_234_567), "1,234,567")
        XCTAssertEqual(Format.count(-1234), "-1,234")
    }

    func testPercent() {
        XCTAssertEqual(Format.percent(0), "0.0%")
        XCTAssertEqual(Format.percent(18.99), "19.0%")
        XCTAssertEqual(Format.percent(12.34), "12.3%")
    }

    func testUptime() {
        XCTAssertEqual(Format.uptime(seconds: 30), "0m")
        XCTAssertEqual(Format.uptime(seconds: 9 * 60), "9m")
        XCTAssertEqual(Format.uptime(seconds: 2 * 3600 + 15 * 60), "2h 15m")
        XCTAssertEqual(
            Format.uptime(seconds: 3 * 86400 + 4 * 3600 + 59), "3d 4h")
    }

    func testKibibytes() {
        XCTAssertEqual(Format.kibibytes(512), "512K")
        XCTAssertEqual(Format.kibibytes(128 * 1024), "128M")
        XCTAssertEqual(Format.kibibytes(3 * 1024 * 1024 + 512 * 1024), "3.5G")
    }

    func testMemoryLabel() {
        var system = SystemInfo()
        system.memUsedPercent = 25
        XCTAssertEqual(Format.memory(system), "25.0%")

        system.memUsedKiB = 1024 * 1024
        system.memTotalKiB = 4 * 1024 * 1024
        XCTAssertEqual(Format.memory(system), "25.0% · 1.0G/4.0G")
    }

    func testCountdown() {
        XCTAssertEqual(Format.countdown(seconds: -5), "0:00")
        XCTAssertEqual(Format.countdown(seconds: 42), "0:42")
        XCTAssertEqual(Format.countdown(seconds: 245), "4:05")
        XCTAssertEqual(Format.countdown(seconds: 3723), "1:02:03")
    }

    func testClock() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(Format.clock(1_700_000_000, timeZone: utc), "22:13:20")
        XCTAssertEqual(Format.clock(0, timeZone: utc), "-")
        XCTAssertEqual(
            Format.shortDateTime(1_700_000_000, timeZone: utc), "Nov 14 22:13")
    }

    func testIssues() {
        XCTAssertEqual(Format.issues(1), "1 issue")
        XCTAssertEqual(Format.issues(4), "4 issues")
    }
}

final class ClassificationTests: XCTestCase {
    func testQueryStatusTone() {
        XCTAssertEqual(QueryStatus.tone("GRAVITY"), .block)
        XCTAssertEqual(QueryStatus.tone("DENYLIST_CNAME"), .block)
        XCTAssertEqual(QueryStatus.tone("REGEX"), .block)
        XCTAssertEqual(QueryStatus.tone("EXTERNAL_BLOCKED_IP"), .block)
        XCTAssertEqual(QueryStatus.tone("SPECIAL_DOMAIN"), .block)
        XCTAssertEqual(QueryStatus.tone("FORWARDED"), .allow)
        XCTAssertEqual(QueryStatus.tone("cache_stale"), .allow)
        XCTAssertEqual(QueryStatus.tone("RETRIED_DNSSEC"), .allow)
        XCTAssertEqual(QueryStatus.tone("IN_PROGRESS"), .neutral)
        XCTAssertEqual(QueryStatus.tone("  "), .neutral)
    }

    func testListStatus() {
        XCTAssertEqual(ListStatus.label(1), "ok")
        XCTAssertEqual(ListStatus.label(3), "error")
        XCTAssertEqual(ListStatus.label(9), "unknown")
        XCTAssertEqual(ListStatus.tone(2), .warn)
        XCTAssertEqual(ListStatus.tone(0), .neutral)
    }

    func testGroupIDs() {
        XCTAssertEqual(GroupIDs.parse("0, 2,5"), [0, 2, 5])
        XCTAssertEqual(GroupIDs.parse(" , x, 3"), [3])
        XCTAssertEqual(GroupIDs.parse(""), [])
        XCTAssertEqual(GroupIDs.csv([0, 2]), "0, 2")
    }

    func testDestructiveHint() {
        let forbidden = PiholeError.api(
            APIError(status: 403, key: "forbidden", message: "No"))
        XCTAssertTrue(
            ErrorText.describeDestructive(forbidden).contains(
                "allow_destructive"))

        let notFound = PiholeError.api(
            APIError(status: 404, key: "not_found", message: "Missing"))
        XCTAssertFalse(
            ErrorText.describeDestructive(notFound).contains(
                "allow_destructive"))
    }

    func testCancellationDetection() {
        XCTAssertTrue(ErrorText.isCancellation(CancellationError()))
        XCTAssertTrue(ErrorText.isCancellation(URLError(.cancelled)))
        XCTAssertFalse(ErrorText.isCancellation(URLError(.timedOut)))
    }
}

final class ConfigTreeTests: XCTestCase {
    private func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    func testFlattensPlainTree() throws {
        let tree = try decode(
            #"""
            {"dns":{"upstreams":["1.1.1.1"],"blocking":{"active":true}},
             "misc":{"nice":-10}}
            """#
        )

        let leaves = ConfigTree.flatten(tree)

        XCTAssertEqual(
            leaves.map(\.path),
            ["dns.blocking.active", "dns.upstreams", "misc.nice"])
        XCTAssertEqual(leaves[0].value, .bool(true))
        XCTAssertEqual(leaves[2].value, .number(-10))
        XCTAssertEqual(leaves[0].section, "dns")
        XCTAssertEqual(leaves[0].name, "blocking.active")
    }

    func testFlattensDetailedTree() throws {
        let tree = try decode(
            """
            {"dns":{"blocking":{"mode":{
                "description":"How to answer blocked queries",
                "type":"enum (string)",
                "allowed":[{"item":"NULL","description":"0.0.0.0"},
                 {"item":"NXDOMAIN","description":"nx"}],
                "default":"NULL","modified":true,
                 "flags":{"restart_dnsmasq":true},"value":"NXDOMAIN"}}}}
            """)

        let leaves = ConfigTree.flatten(tree)

        XCTAssertEqual(leaves.count, 1)
        let leaf = try XCTUnwrap(leaves.first)
        XCTAssertEqual(leaf.path, "dns.blocking.mode")
        XCTAssertEqual(leaf.value, .string("NXDOMAIN"))
        XCTAssertEqual(leaf.defaultValue, .string("NULL"))
        XCTAssertEqual(leaf.dataType, "enum (string)")
        XCTAssertTrue(leaf.modified)
        XCTAssertEqual(ConfigTree.allowedInputs(leaf), ["NULL", "NXDOMAIN"])
        XCTAssertEqual(
            ConfigTree.editKind(leaf), .choice(["NULL", "NXDOMAIN"]))
        XCTAssertEqual(ConfigTree.typeLabel(leaf), "enum (string)")
    }

    func testObjectWithOnlyValueKeyIsNotADetailLeaf() throws {
        let tree = try decode(#"{"a":{"value":1}}"#)
        XCTAssertEqual(ConfigTree.flatten(tree).map(\.path), ["a.value"])
    }

    func testFilter() {
        let leaves = [
            ConfigLeaf(path: "dns.upstreams", value: .array([])),
            ConfigLeaf(
                path: "webserver.api.allow_destructive", value: .bool(false)),
        ]
        XCTAssertEqual(
            ConfigTree.filter(leaves, query: "  DESTRUCT ").map(\.path),
            ["webserver.api.allow_destructive"])
        XCTAssertEqual(ConfigTree.filter(leaves, query: "").count, 2)
    }

    func testStringify() {
        XCTAssertEqual(ConfigTree.stringify(nil), "null")
        XCTAssertEqual(ConfigTree.stringify(.null), "null")
        XCTAssertEqual(ConfigTree.stringify(.bool(false)), "false")
        XCTAssertEqual(ConfigTree.stringify(.number(53)), "53")
        XCTAssertEqual(ConfigTree.stringify(.number(0.5)), "0.5")
        XCTAssertEqual(
            ConfigTree.stringify(.array([.string("a"), .number(2)])), "[a, 2]")
        XCTAssertEqual(ConfigTree.stringify(.object([:])), "{…}")
    }

    func testEditKinds() {
        XCTAssertEqual(
            ConfigTree.editKind(ConfigLeaf(path: "a", value: .bool(true))),
            .toggle)
        XCTAssertEqual(
            ConfigTree.editKind(ConfigLeaf(path: "a", value: .number(1))),
            .number)
        XCTAssertEqual(
            ConfigTree.editKind(ConfigLeaf(path: "a", value: .string("x"))),
            .text)
        XCTAssertEqual(
            ConfigTree.editKind(
                ConfigLeaf(path: "a", value: .array([.string("x")]))),
            .stringList)
        XCTAssertEqual(
            ConfigTree.editKind(ConfigLeaf(path: "a", value: .array([]))),
            .stringList)
        XCTAssertEqual(
            ConfigTree.editKind(
                ConfigLeaf(path: "a", value: .array([.number(1)]))), .readOnly)
        XCTAssertEqual(
            ConfigTree.editKind(ConfigLeaf(path: "a", value: .null)), .readOnly)
    }

    func testParseKeepsOriginalType() throws {
        XCTAssertEqual(
            try ConfigTree.parse(original: .bool(false), input: " true "),
            .bool(true))
        XCTAssertEqual(
            try ConfigTree.parse(original: .number(1), input: "85"), .number(85)
        )
        XCTAssertEqual(
            try ConfigTree.parse(original: .number(1), input: "0.25"),
            .number(0.25))
        XCTAssertEqual(
            try ConfigTree.parse(original: .string("a"), input: " b "),
            .string("b"))
        XCTAssertThrowsError(
            try ConfigTree.parse(original: .number(1), input: "lots"))
        XCTAssertThrowsError(
            try ConfigTree.parse(original: .bool(true), input: "maybe"))
    }

    func testPatchNestsPath() {
        XCTAssertEqual(
            ConfigTree.patch(path: "misc.temp.limit", value: .number(85)),
            .object(["misc": .object(["temp": .object(["limit": .number(85)])])]
            )
        )
        XCTAssertEqual(
            ConfigTree.patch(path: "top", value: .bool(true)),
            .object(["top": .bool(true)]))
    }

    func testInfoRowsFlattenNestedSections() throws {
        let info = try decode(
            #"""
            {"model":"Pi 4","uname":{"sysname":"Linux","release":"6.6"},
             "dns":["a","b"],"skip":[{"x":1}],"none":null}
            """#
        )

        let rows = InfoRows.flatten(info)

        XCTAssertEqual(
            rows.map(\.key), ["dns", "model", "uname.release", "uname.sysname"])
        XCTAssertEqual(rows.first?.value, "a, b")
    }
}

final class AppConfigTests: XCTestCase {
    func testConfigSavedBeforeCombinedStillLoads() throws {
        let old = Data(#"{"theme":"nord","instances":[]}"#.utf8)
        let config = try JSONDecoder().decode(AppConfig.self, from: old)
        XCTAssertEqual(config.theme, "nord")
        XCTAssertFalse(config.combined)

        var on = config
        on.combined = true
        let roundTrip = try JSONDecoder().decode(
            AppConfig.self, from: JSONEncoder().encode(on))
        XCTAssertTrue(roundTrip.combined)
    }

    func testValidConfig() {
        let home = InstanceConfig(name: "home", url: "https://pi.hole")
        let config = AppConfig(activeID: home.id, instances: [home])
        XCTAssertEqual(config.validationErrors(), [])
        XCTAssertEqual(config.activeInstance, home)
    }

    func testEmptyConfig() {
        XCTAssertEqual(
            AppConfig().validationErrors(), ["no instances configured"])
        XCTAssertNil(AppConfig().activeInstance)
    }

    func testDuplicateAndMissingNames() {
        let first = InstanceConfig(name: "home", url: "http://10.0.0.53")
        let second = InstanceConfig(name: "home", url: "http://10.0.0.54")
        let third = InstanceConfig(name: " ", url: "ftp://nope")
        let errors = AppConfig(
            activeID: first.id, instances: [first, second, third]
        ).validationErrors()

        XCTAssertTrue(errors.contains("instance \"home\": duplicate name"))
        XCTAssertTrue(errors.contains("instance 3: name is required"))
        XCTAssertTrue(
            errors.contains(
                "instance \"#3\": url must start with http:// or https://"))
    }

    func testActiveMustMatch() {
        let home = InstanceConfig(name: "home", url: "https://pi.hole")
        XCTAssertEqual(
            AppConfig(activeID: UUID(), instances: [home]).validationErrors(),
            ["active instance does not match any instance"]
        )
        XCTAssertEqual(
            AppConfig(activeID: nil, instances: [home]).validationErrors(),
            ["active instance is required"]
        )
        // A stale active id still resolves to something usable.
        XCTAssertEqual(
            AppConfig(activeID: UUID(), instances: [home]).activeInstance, home)
    }

    func testURLProblems() {
        XCTAssertNil(InstanceConfig.urlProblem("https://pi.hole"))
        XCTAssertNil(InstanceConfig.urlProblem("http://10.0.0.53:8080"))
        XCTAssertEqual(InstanceConfig.urlProblem(""), "url is required")
        XCTAssertEqual(
            InstanceConfig.urlProblem("pi.hole"),
            "url must start with http:// or https://")
        XCTAssertEqual(InstanceConfig.urlProblem("http://"), "url has no host")
    }

    func testNormalizedURL() {
        XCTAssertEqual(
            InstanceConfig.normalizedURL(" pi.hole "), "https://pi.hole")
        XCTAssertEqual(
            InstanceConfig.normalizedURL("10.0.0.53/"), "https://10.0.0.53")
        XCTAssertEqual(
            InstanceConfig.normalizedURL("HTTPS://pi.hole/admin/"),
            "HTTPS://pi.hole/admin")
        XCTAssertEqual(InstanceConfig.normalizedURL(""), "")
    }

    func testFirstInstanceBecomesActive() {
        let (config, id) = AppConfig().upserting(
            id: nil, name: "home", url: "https://pi.hole", verifyTLS: true
        )

        XCTAssertEqual(config.instances.map(\.id), [id])
        XCTAssertEqual(config.activeID, id)
    }

    func testEditKeepsIDAndActive() {
        let home = InstanceConfig(name: "home", url: "https://pi.hole")
        let lab = InstanceConfig(name: "lab", url: "https://lab.lan")
        let start = AppConfig(activeID: home.id, instances: [home, lab])

        let (config, id) = start.upserting(
            id: lab.id, name: "lab2", url: "https://lab2.lan", verifyTLS: false
        )

        XCTAssertEqual(id, lab.id)
        XCTAssertEqual(config.activeID, home.id)
        XCTAssertEqual(config.instances.count, 2)
        XCTAssertEqual(config.instances[1].name, "lab2")
        XCTAssertEqual(config.instances[1].url, "https://lab2.lan")
        XCTAssertFalse(config.instances[1].verifyTLS)
    }

    func testAddingSecondInstanceKeepsActive() {
        let home = InstanceConfig(name: "home", url: "https://pi.hole")
        let start = AppConfig(activeID: home.id, instances: [home])

        let (config, id) = start.upserting(
            id: nil, name: "lab", url: "https://lab.lan", verifyTLS: true
        )

        XCTAssertNotEqual(id, home.id)
        XCTAssertEqual(config.activeID, home.id)
    }

    func testRemovingActivePicksFirstRemaining() {
        let home = InstanceConfig(name: "home", url: "https://pi.hole")
        let lab = InstanceConfig(name: "lab", url: "https://lab.lan")
        let start = AppConfig(activeID: home.id, instances: [home, lab])

        XCTAssertEqual(start.removing(home.id).activeID, lab.id)
        XCTAssertEqual(start.removing(lab.id).activeID, home.id)
        XCTAssertNil(start.removing(home.id).removing(lab.id).activeID)
    }

    func testConfigRoundTripsThroughJSON() throws {
        let home = InstanceConfig(
            name: "home", url: "https://pi.hole", verifyTLS: false)
        let config = AppConfig(
            activeID: home.id, theme: "deep-night", instances: [home])

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(decoded, config)
    }

    /// Config exactly as 1.0.1 saved it. The app falls back to an empty
    /// config when decoding fails, so a schema change that breaks this would
    /// silently drop every saved instance on upgrade.
    func testDecodesConfigSavedByFirstRelease() throws {
        let id = "5E1C7A2B-0D4F-4C3A-9B8E-1F2A3B4C5D6E"
        let saved = """
            {"activeID":"\(id)","theme":"gloss","instances":[{"id":"\(id)",\
            "name":"home","url":"https://pi.hole","verifyTLS":false}]}
            """

        let config = try JSONDecoder().decode(
            AppConfig.self, from: Data(saved.utf8))

        XCTAssertEqual(config.activeInstance?.id, UUID(uuidString: id))
        XCTAssertEqual(config.activeInstance?.url, "https://pi.hole")
        XCTAssertEqual(config.activeInstance?.verifyTLS, false)
        XCTAssertEqual(config.theme, "gloss")
    }
}

final class InstanceRowsTests: XCTestCase {
    func testActiveFirstThenConfigOrder() {
        let rows = InstanceRows.build(
            order: ["a", "b", "c"], active: "b",
            health: [
                "b": .success(MemberHealth(messages: 0)),
                "c": .failure(MemberError.unreachable),
            ],
            gravity: ["b": 5])

        XCTAssertEqual(rows.map(\.name), ["b", "a", "c"])
        XCTAssertTrue(rows[0].isActive)
        XCTAssertEqual(rows[0].gravity, 5)
        XCTAssertNil(rows[1].health, "a has not been probed yet")
        XCTAssertFalse(rows[1].isUnreachable)
        XCTAssertTrue(rows[2].isUnreachable)
    }

    func testCommonGravityPrefersMajorityThenEarliest() {
        func row(_ gravity: Int?, down: Bool = false) -> InstanceRow {
            InstanceRow(
                name: "x", isActive: false, health: nil,
                isUnreachable: down, gravity: gravity)
        }
        XCTAssertEqual(
            InstanceRows.commonGravity([row(1), row(2), row(2)]), 2)
        XCTAssertEqual(InstanceRows.commonGravity([row(3), row(4)]), 3)
        XCTAssertEqual(
            InstanceRows.commonGravity([row(9, down: true), row(4)]), 4)
        XCTAssertNil(InstanceRows.commonGravity([row(nil)]))
    }
}

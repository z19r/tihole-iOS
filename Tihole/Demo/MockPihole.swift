import Foundation
import Network

/// A tiny HTTP server that answers like Pi-hole's FTL API with canned data.
///
/// It listens on a loopback port only. The app runs one as its demo Pi-hole
/// (see `startDemo`), so people without a Pi-hole, App Review included, can try
/// every screen. The UI tests run their own copy inside the test runner and
/// point the app at `http://127.0.0.1:<port>`. Like FTL it rejects requests
/// that do not carry the session id it issued at login, so the app's real login
/// path is exercised.
final class MockPihole {
    struct Request {
        let method: String
        let path: String
        let query: String
        let headers: [String: String]
        let body: Data
    }

    struct Response {
        var status = 200
        var contentType = "application/json"
        var body = Data()

        static func json(_ text: String, status: Int = 200) -> Response {
            Response(
                status: status, contentType: "application/json",
                body: Data(text.utf8))
        }

        static func text(_ text: String) -> Response {
            Response(
                status: 200, contentType: "text/plain", body: Data(text.utf8))
        }
    }

    enum Failure: Error {
        case noPort
    }

    static let sessionID = "mock-session"
    static let password = "mock-password"

    /// The demo instance's address. The port is fixed so the saved instance
    /// still points at the server after the app relaunches.
    static let demoURL = "http://127.0.0.1:47053"
    @MainActor private static var demo: MockPihole?

    /// Starts the in-app demo server, or restarts it if iOS tore its socket
    /// down while the app was suspended.
    @MainActor static func startDemo() throws {
        if demo?.listener.state == .ready {
            return
        }
        demo?.stop()
        demo = nil
        let server = try MockPihole(port: 47053)
        try server.start()
        demo = server
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "mock-pihole")

    // Mutable server state, touched only on `queue`.
    private var blockingEnabled = true
    private var blockingResumesAt: Date?

    private(set) var port: UInt16 = 0

    init(port: NWEndpoint.Port = .any) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback), port: port)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            connection.start(queue: self.queue)
            self.receive(on: connection, buffer: Data())
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 10)

        guard let assigned = listener.port?.rawValue, assigned != 0 else {
            throw Failure.noPort
        }
        port = assigned
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - HTTP plumbing

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024)
        { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            if let request = MockPihole.parse(buffer) {
                let response = self.respond(to: request)
                connection.send(
                    content: MockPihole.serialize(response),
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: buffer)
        }
    }

    /// Parses one HTTP/1.1 request, or returns nil until the head and the
    /// whole body (per Content-Length) have arrived.
    private static func parse(_ buffer: Data) -> Request? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headEnd = buffer.range(of: separator) else {
            return nil
        }
        let head = String(
            decoding: buffer[buffer.startIndex..<headEnd.lowerBound],
            as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            return nil
        }
        let requestLine = lines.removeFirst().split(separator: " ").map(
            String.init)
        guard requestLine.count >= 2 else {
            return nil
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let name = line[line.startIndex..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(
                in: .whitespaces)
            headers[name] = value
        }

        let length = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = headEnd.upperBound
        guard buffer.endIndex - bodyStart >= length else {
            return nil
        }
        let body = buffer[bodyStart..<(bodyStart + length)]

        let target = requestLine[1]
        let parts = target.split(separator: "?", maxSplits: 1).map(String.init)
        return Request(
            method: requestLine[0],
            path: parts.first ?? target,
            query: parts.count > 1 ? parts[1] : "",
            headers: headers,
            body: Data(body)
        )
    }

    private static func serialize(_ response: Response) -> Data {
        let reason = response.status == 200 ? "OK" : "Status"
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        return data
    }

    // MARK: - Routes

    private func respond(to request: Request) -> Response {
        let path =
            request.path.hasPrefix("/api")
            ? String(request.path.dropFirst(4)) : request.path

        if path == "/auth" && request.method == "POST" {
            let sent = String(decoding: request.body, as: UTF8.self)
            guard sent.contains(MockPihole.password) else {
                return .json(
                    #"""
                    {"session":{"valid":false,"sid":null,
                     "message":"password incorrect"},"took":0}
                    """#,
                    status: 401)
            }
            return .json(
                #"""
                {"session":{"valid":true,"sid":"\#(MockPihole.sessionID)",
                 "csrf":"c","validity":1800,"totp":false},"took":0}
                """#
            )
        }

        guard request.headers["x-ftl-sid"] == MockPihole.sessionID else {
            return .json(
                #"""
                {"error":{"key":"unauthorized","message":"Unauthorized",
                 "hint":null},"took":0}
                """#,
                status: 401)
        }

        if path == "/auth" && request.method == "DELETE" {
            return Response(status: 204)
        }

        if path == "/dns/blocking" {
            if request.method == "POST" {
                let sent =
                    (try? JSONSerialization.jsonObject(with: request.body))
                    as? [String: Any]
                blockingEnabled = sent?["blocking"] as? Bool ?? true
                let seconds = blockingEnabled ? nil : sent?["timer"] as? Double
                blockingResumesAt = seconds.map {
                    Date().addingTimeInterval($0)
                }
            }
            if let resumesAt = blockingResumesAt, resumesAt <= Date() {
                blockingEnabled = true
                blockingResumesAt = nil
            }
            let state = blockingEnabled ? "enabled" : "disabled"
            let timer =
                blockingResumesAt.map {
                    String(Int($0.timeIntervalSinceNow.rounded()))
                } ?? "null"
            return .json(
                #"{"blocking":"\#(state)","timer":\#(timer),"took":0}"#)
        }

        if path == "/action/gravity" {
            return .text(
                """
                [i] Neutrino emissions detected...\n[✓] Pulling blocklist \
                source list into range\n[✓] Done.\n
                """
            )
        }

        if path.hasPrefix("/config/dns/hosts") {
            return .json(
                #"""
                {"config":{"dns":{"hosts":["10.0.0.2 nas.lan",
                 "10.0.0.3 printer.lan"]}},"took":0}
                """#
            )
        }
        if path.hasPrefix("/config/dns/cnameRecords") {
            return .json(
                #"""
                {"config":{"dns":{"cnameRecords":["files.lan,nas.lan",
                 "media.lan,nas.lan,300"]}},"took":0}
                """#
            )
        }

        if let fixture = MockPihole.fixtures[path] {
            return .json(fixture)
        }
        return .json(#"{"took":0}"#)
    }

    /// Canned bodies for the read-only endpoints, keyed by path below /api.
    private static let fixtures: [String: String] = [
        "/stats/summary": """
        {"queries":{"total":48213,"blocked":9127,"percent_blocked":18.93,
         "unique_domains":3120,
                    "forwarded":21044,"cached":18042,"frequency":0.56},
         "clients":{"active":14,"total":31},
         "gravity":{"domains_being_blocked":172944,"last_update":1763300000},
          "took":0}
        """,
        "/history": MockPihole.historyFixture(),
        "/stats/query_types":
            #"""
        {"types":{"A":28110,"AAAA":14021,"HTTPS":4102,"PTR":1320,"SRV":410,
         "TXT":250},"took":0}
        """#,
        "/stats/upstreams": """
        {"upstreams":[{"ip":"blocklist","name":"blocklist","port":-1,
         "count":9127,"statistics":{"response":0,"variance":0}},
                      {"ip":"cache","name":"cache","port":-1,"count":18042,
                       "statistics":{"response":0,"variance":0}},
                      {"ip":"1.1.1.1","name":"one.one.one.one","port":53,
                       "count":12800,"statistics":{"response":0.012,
                       "variance":0.001}},
                      {"ip":"9.9.9.9","name":"dns.quad9.net","port":53,
                       "count":8244,"statistics":{"response":0.018,
                       "variance":0.002}}],
         "forwarded_queries":21044,"total_queries":48213,"took":0}
        """,
        "/stats/top_domains": """
        {"domains":[{"domain":"api.github.com","count":2210},
         {"domain":"gateway.icloud.com","count":1804},
                    {"domain":"ads.example.com","count":1502},
                     {"domain":"time.apple.com","count":990},
                    {"domain":"telemetry.example.net","count":811}],
         "total_queries":48213,"blocked_queries":9127,"took":0}
        """,
        "/stats/top_clients": """
        {"clients":[{"ip":"10.0.0.21","name":"framework.lan","count":12044},
         {"ip":"10.0.0.34","name":"living-room-tv.lan","count":9310},
                    {"ip":"10.0.0.40","name":"","count":4120},{"ip":"10.0.0.2",
                     "name":"nas.lan","count":2204}],
         "total_queries":48213,"blocked_queries":9127,"took":0}
        """,
        "/info/system": """
        {"system":{"uptime":786000,"procs":142,
          "memory":{"ram":{"total":3884000,"used":1204000,"%used":31.0},
           "swap":{"%used":0.0}},
          "cpu":{"nprocs":4,"%cpu":7.4,"load":{"raw":[0.31,0.28,0.22],
           "percent":[7.8,7.0,5.5]}},
          "ftl":{"%mem":1.2,"%cpu":0.4}},"took":0}
        """,
        "/info/sensors":
            #"""
        {"sensors":{"cpu_temp":51.6,"hot_limit":85,"unit":"C"},"took":0}
        """#,
        "/info/messages": """
        {"messages":[{"id":3,"timestamp":1763300100,"type":"RATE_LIMIT",
                      "plain":"Client 10.0.0.40 has been rate-limited for \
        at least 30 seconds.",
                      "html":"","url":""}],"took":0}
        """,
        "/info/messages/count": #"{"count":1,"took":0}"#,
        "/queries": """
        {"queries":[
          {"id":9004,"time":1763300400.5,"type":"A","domain":"api.github.com",
           "cname":null,"status":"FORWARDED",
           "client":{"ip":"10.0.0.21","name":"framework.lan"},
            "dnssec":"INSECURE","reply":{"type":"IP","time":0.0121},
            "list_id":null,"upstream":"1.1.1.1#53"},
          {"id":9003,"time":1763300398.1,"type":"A","domain":"ads.example.com",
           "cname":null,"status":"GRAVITY",
           "client":{"ip":"10.0.0.34","name":"living-room-tv.lan"},
            "dnssec":"UNKNOWN","reply":{"type":"NODATA","time":0.0002},
            "list_id":1,"upstream":null},
          {"id":9002,"time":1763300395.7,"type":"AAAA",
           "domain":"gateway.icloud.com","cname":null,"status":"CACHE",
           "client":{"ip":"10.0.0.40","name":null},"dnssec":"INSECURE",
            "reply":{"type":"IP","time":0.0001},"list_id":null,"upstream":null},
          {"id":9001,"time":1763300391.2,"type":"HTTPS",
           "domain":"telemetry.example.net","cname":null,"status":"DENYLIST",
           "client":{"ip":"10.0.0.21","name":"framework.lan"},
            "dnssec":"UNKNOWN","reply":{"type":"NODATA","time":0.0002},
            "list_id":4,"upstream":null}],
         "cursor":9004,"recordsFiltered":4,"recordsTotal":48213,
          "draft_cursor":null,"took":0}
        """,
        "/domains": """
        {"domains":[
          {"domain":"telemetry.example.net","unicode":"telemetry.example.net",
           "type":"deny","kind":"exact","comment":"smart TV phone-home",
           "groups":[0],"enabled":true,"id":4,"date_added":1763000000,
            "date_modified":1763000000},
          {"domain":"(^|\\\\.)doubleclick\\\\.net$",
           "unicode":"(^|\\\\.)doubleclick\\\\.net$","type":"deny",
           "kind":"regex","comment":null,
           "groups":[0,1],"enabled":true,"id":5,"date_added":1763000000,
            "date_modified":1763000000},
          {"domain":"clients4.google.com","unicode":"clients4.google.com",
           "type":"allow","kind":"exact",
           "comment":"breaks captive portal check",
           "groups":[0],"enabled":false,"id":6,"date_added":1763000000,
            "date_modified":1763000000}],"took":0}
        """,
        "/groups": """
        {"groups":[{"name":"Default","comment":"The default group",
         "enabled":true,"id":0,"date_added":1,"date_modified":1},
                   {"name":"kids","comment":"Tablets and consoles",
                    "enabled":true,"id":1,"date_added":1,"date_modified":1}],
                    "took":0}
        """,
        "/clients": """
        {"clients":[{"client":"10.0.0.34","comment":"Living room TV",
         "groups":[0,1],"id":1,"name":"living-room-tv.lan",
                     "date_added":1,"date_modified":1}],"took":0}
        """,
        "/clients/_suggestions": """
        {"clients":[{"hwaddr":"aa:bb:cc:dd:ee:01",
         "macVendor":"Framework Computer","lastQuery":1763300400,
                     "name":"framework.lan","addresses":"10.0.0.21"}],"took":0}
        """,
        "/lists": """
        {"lists":[{"address":"https://raw.githubusercontent.com/\
        StevenBlack/hosts/master/hosts",
         "comment":"StevenBlack unified",
                   "type":"block","groups":[0],"enabled":true,"id":1,
                    "number":172944,"invalid_domains":2,"status":1,
                   "date_added":1,"date_modified":1,"date_updated":1763300000}],
                    "took":0}
        """,
        "/config": """
        {"config":{
          "dns":{
            "upstreams":{"description":"Upstream DNS servers used by Pi-hole.",
             "type":"string array","allowed":"array of IP addresses",
                         "default":[],"modified":true,
                          "flags":{"restart_dnsmasq":true},"value":["1.1.1.1",
                          "9.9.9.9"]},
            "blocking":{
              "active":{"description":"Should FTL block queries?",
               "type":"boolean","allowed":"true or false",
                        "default":true,"modified":false,"flags":{},
                         "value":true},
              "mode":{"description":"How should FTL reply to blocked queries?",
               "type":"enum (string)",
                      "allowed":[{"item":"NULL",
                       "description":"Unspecified address"},{"item":"NXDOMAIN",
                       "description":"No such domain"}],
                      "default":"NULL","modified":false,"flags":{},
                       "value":"NULL"}}},
          "misc":{"temp":{"limit":{"description":"Which upper temperature \
        limit should be used?",
           "type":"double","allowed":"any",
                                   "default":60.0,"modified":true,"flags":{},
                                    "value":85.0}}},
          "webserver":{"api":{"allow_destructive":{
           "description":"Allow destructive API calls.",
           "type":"boolean","allowed":"true or false",
                                                   "default":true,
                                                    "modified":false,"flags":{},
                                                    "value":true}}}},"took":0}
        """,
        "/info/ftl":
            #"""
        {"ftl":{"database":{"gravity":172944,"groups":2,"lists":1,
         "clients":1},"privacy_level":0,"pid":812,"uptime":786000.5},
         "took":0}
        """#,
        "/info/host":
            #"""
        {"host":{"uname":{"domainname":"(none)","machine":"aarch64",
         "nodename":"z19r-networking","release":"6.12.25",
         "sysname":"Linux"},"model":"Raspberry Pi 4 Model B Rev 1.5"},
         "took":0}
        """#,
        "/info/version":
            #"""
        {"version":{"core":{"local":{"version":"v6.2.1","branch":"master"}},
         "ftl":{"local":{"version":"v6.3.2","branch":"master"}},
         "web":{"local":{"version":"v6.3","branch":"master"}}},"took":0}
        """#,
        "/network/devices": """
        {"devices":[{"id":1,"hwaddr":"aa:bb:cc:dd:ee:01","interface":"eth0",
         "firstSeen":1760000000,"lastQuery":1763300400,
                     "numQueries":12044,"macVendor":"Framework Computer",
                      "ips":[{"ip":"10.0.0.21","name":"framework.lan",
                      "lastSeen":1763300400}]},
                    {"id":2,"hwaddr":"aa:bb:cc:dd:ee:02","interface":"eth0",
                     "firstSeen":1760000000,"lastQuery":1763300398,
                     "numQueries":9310,"macVendor":null,
                      "ips":[{"ip":"10.0.0.34","name":"living-room-tv.lan",
                      "lastSeen":1763300398}]}],"took":0}
        """,
        "/info/logs/dns": """
        {"log":[{"timestamp":1763300398.1,
         "message":"query[A] ads.example.com from 10.0.0.34","prio":null},
                {"timestamp":1763300398.1,
                 "message":"gravity blocked ads.example.com is 0.0.0.0",
                 "prio":null},
                {"timestamp":1763300400.5,
                 "message":"query[A] api.github.com from 10.0.0.21",
                 "prio":null}],"nextID":3,"took":0}
        """,
    ]

    /// A day of ten-minute buckets with a gentle daily curve.
    private static func historyFixture() -> String {
        let start = 1_763_214_000
        var buckets: [String] = []
        for index in 0..<144 {
            let wave = sin(Double(index) / 144 * 2 * Double.pi - 1.2)
            let total = Int(330 + 220 * wave) + (index * 37) % 60
            let blocked = total / 5 + (index * 13) % 20
            let cached = total / 3
            let forwarded = max(0, total - blocked - cached)
            buckets.append(
                #"""
                {"timestamp":\#(start + index * 600),"total":\#(total),
                 "cached":\#(cached),"blocked":\#(blocked),
                 "forwarded":\#(forwarded)}
                """#
            )
        }
        return #"{"history":["# + buckets.joined(separator: ",")
            + #"],"took":0}"#
    }
}

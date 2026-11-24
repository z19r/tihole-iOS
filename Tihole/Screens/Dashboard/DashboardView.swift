import Charts
import PiholeKit
import SwiftUI
import TiholeCore

/// Runs `operation` and returns its outcome as a value, so several fetches
/// can run side by side and each fail on its own.
func capture<T>(_ operation: @Sendable () async throws -> T) async -> Result<
    T, Error
> {
    do {
        return .success(try await operation())
    } catch {
        return .failure(error)
    }
}

/// Like `capture`, but skipped when `run` is false. A skipped fetch reports
/// cancellation, which the dashboard treats as "keep the last value".
func capture<T>(
    if run: Bool,
    _ operation: @Sendable () async throws -> T
) async -> Result<T, Error> {
    guard run else {
        return .failure(CancellationError())
    }
    return await capture(operation)
}

/// The combined call when `combined` is set, else the single-instance one,
/// so each dashboard fetch picks its source in one place.
func readStats<T: Sendable>(
    _ combined: CombinedClient?,
    _ merged: @Sendable (CombinedClient) async throws -> Combined<T>,
    _ single: @Sendable () async throws -> T
) async throws -> Combined<T> {
    if let combined {
        return try await merged(combined)
    }
    return Combined(value: try await single())
}

/// Everything the dashboard shows, plus a per-panel error so one failed
/// endpoint never blanks the rest.
struct DashboardData {
    var summary = Summary()
    var history = QueryHistory()
    var types = QueryTypes()
    var upstreams = Upstreams()
    var topDomains = TopDomains()
    var topBlocked = TopDomains()
    var topClients = TopClients()
    var system = SystemInfo()
    var sensors = Sensors()
    var messages: [DiagnosisMessage] = []

    var summaryError: String?
    var historyError: String?
    var typesError: String?
    var upstreamsError: String?
    var topDomainsError: String?
    var topBlockedError: String?
    var topClientsError: String?
    var systemError: String?
    var messagesError: String?

    /// Pi-holes left out of the last combined refresh.
    var unreachable: [String] = []
    /// Combined mode: each other Pi-hole's machine stats, from the slow
    /// probe, and each Pi-hole's gravity, from the summary fetch.
    var memberHealth: [String: Result<MemberHealth, Error>] = [:]
    var memberGravity: [String: Int] = [:]

    /// True once the first refresh has completed.
    var loaded = false
}

/// A label and a count, for the breakdown and top-N panels.
struct LabeledCount: Identifiable {
    let label: String
    let count: Int
    var id: String { label }
}

/// One point of the queries-over-time chart.
struct HistorySeriesPoint: Identifiable {
    let date: Date
    let kind: String
    let count: Int
    var id: String { "\(kind)-\(date.timeIntervalSince1970)" }
}

struct DashboardView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    @State private var data = DashboardData()
    @State private var hotLimitPrompted = false
    @State private var showingHotLimitPrompt = false
    @State private var actionError: String?
    @State private var slowFetchedAt = Date.distantPast

    /// Rows shown in each top-N panel.
    private let topCount = 8
    /// Seconds between refreshes while the dashboard is on screen.
    private let pollInterval = 3.0
    /// Seconds between refreshes of history, sensors and messages. History
    /// comes in 10-minute buckets and the other two rarely change.
    private let slowInterval = 30.0
    /// Pi-hole's stock hot-temperature threshold, and the one offered instead.
    private let hotLimitDefault = 60.0
    private let hotLimitSuggested = 85.0

    private let columns = [
        GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let problem = app.connectionProblem {
                    ErrorBanner(message: problem)
                }
                if let actionError {
                    ErrorBanner(message: actionError)
                }
                if !data.unreachable.isEmpty {
                    ErrorBanner(
                        message: """
                            Not reachable: \
                            \(data.unreachable.joined(separator: ", ")). \
                            Showing the rest.
                            """)
                }

                if !data.loaded && app.canRead {
                    ProgressView("Loading dashboard…")
                        .tint(theme.accent)
                        .foregroundStyle(theme.subtle)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    tiles
                    health
                    historyChart
                    breakdown(
                        "Query Types", items: typeItems, error: data.typesError)
                    breakdown(
                        "Upstreams", items: upstreamItems,
                        error: data.upstreamsError)
                    topList(
                        "Top Domains", items: domainItems(data.topDomains),
                        error: data.topDomainsError, color: theme.accent)
                    topList(
                        "Top Blocked", items: domainItems(data.topBlocked),
                        error: data.topBlockedError, color: theme.block)
                    topList(
                        "Top Clients", items: clientItems,
                        error: data.topClientsError, color: theme.accent)
                }
            }
            .padding(12)
        }
        .screenStyle()
        .navigationTitle("Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        .chrome(readsCombined: true)
        .refreshable {
            await refresh(force: true)
        }
        .task(id: app.generation) {
            data = DashboardData()
            slowFetchedAt = .distantPast
            hotLimitPrompted = false
            actionError = nil
            await repeatEvery(pollInterval) {
                await refresh()
            }
        }
        .alert(
            "Raise hot-temperature threshold?",
            isPresented: $showingHotLimitPrompt
        ) {
            Button("Raise to 85°C") {
                Task {
                    await raiseHotLimit()
                }
            }
            Button("Keep 60°C", role: .cancel) {}
        } message: {
            Text(
                """
                Pi-hole's hot-temperature threshold is 60°C, but most \
                single-board computers idle at 45 to 60°C and reach 60 to 70°C \
                under normal load, so 60°C trips false \"hot\" warnings on the \
                health gauge. 85°C is closer to where these CPUs actually \
                throttle.
                """
            )
        }
    }

    // MARK: - Tiles

    private var tiles: some View {
        VStack(spacing: 10) {
            if let error = data.summaryError {
                ErrorBanner(message: "Summary unavailable: \(error)")
            }
            LazyVGrid(columns: columns, spacing: 10) {
                statTile(
                    "Total Queries",
                    value: Format.count(data.summary.queries.total))
                blockedTile
                statTile(
                    "Active Clients",
                    value: Format.count(data.summary.clients.active))
                statTile(
                    data.summary.gravityMismatch
                        ? "Gravity Domains ≠" : "Gravity Domains",
                    value: Format.count(
                        data.summary.gravity.domainsBeingBlocked))
            }
        }
    }

    private func statTile(_ label: String, value: String) -> some View {
        Card {
            Text(label)
                .font(.caption)
                .foregroundStyle(theme.subtle)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(theme.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var blockedTile: some View {
        Card {
            Text("Blocked")
                .font(.caption)
                .foregroundStyle(theme.subtle)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.count(data.summary.queries.blocked))
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(theme.accent)
                Text(Format.percent(data.summary.queries.percentBlocked))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(theme.subtle)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            ProgressView(
                value: clamp(data.summary.queries.percentBlocked / 100)
            )
            .tint(theme.accent)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Health

    @ViewBuilder
    private var health: some View {
        if app.isCombined {
            instanceRows
        } else {
            VStack(spacing: 10) {
                if let error = data.systemError, data.system.nprocs == 0 {
                    ErrorBanner(message: "System unavailable: \(error)")
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        gaugeTile(
                            "CPU",
                            value: Format.percent(data.system.cpuPercent),
                            fraction: data.system.cpuPercent / 100
                        )
                        gaugeTile(
                            "Memory",
                            value: Format.memory(data.system),
                            fraction: data.system.memUsedPercent / 100
                        )
                        temperatureTile
                        loadTile
                    }
                }
                diagnosticsTile
            }
        }
    }

    // MARK: - Per-instance rows

    /// Every Pi-hole, active first: machine stats cannot be combined.
    private var rows: [InstanceRow] {
        var health = data.memberHealth
        if let active = app.activeInstance?.name, app.client != nil {
            health[active] =
                data.systemError != nil && data.system.nprocs == 0
                ? .failure(MemberError.unreachable)
                : .success(
                    MemberHealth(
                        system: data.system, sensors: data.sensors,
                        messages: data.messagesError == nil
                            ? data.messages.count : nil))
        }
        return InstanceRows.build(
            order: app.config.instances.map(\.name),
            active: app.activeInstance?.name, health: health,
            gravity: data.memberGravity)
    }

    private var instanceRows: some View {
        let all = rows
        let common = InstanceRows.commonGravity(all)
        return Card("Pi-holes") {
            ForEach(all.prefix(InstanceRows.limit)) { row in
                instanceRow(row, common: common)
            }
            if all.count > InstanceRows.limit {
                Text("and \(all.count - InstanceRows.limit) more…")
                    .font(.caption)
                    .foregroundStyle(theme.subtle)
            }
        }
    }

    private func instanceRow(_ row: InstanceRow, common: Int?) -> some View {
        let marker = row.isActive ? "▸" : row.isUnreachable ? "○" : "●"
        let gravityDiffers =
            row.gravity != nil && common != nil && row.gravity != common
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(marker)
                    .foregroundStyle(row.isActive ? theme.accent : theme.subtle)
                    .accessibilityHidden(true)
                Text(row.name)
                    .font(.subheadline.weight(row.isActive ? .bold : .regular))
                    .accessibilityLabel(
                        row.isActive ? "\(row.name), active" : row.name
                    )
                    .foregroundStyle(
                        row.isUnreachable ? theme.subtle : theme.text
                    )
                    .lineLimit(1)
                Spacer()
                healthLabel(row)
            }
            HStack {
                Text(machineStats(row))
                    .foregroundStyle(theme.subtle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                if let gravity = row.gravity {
                    Text(Format.count(gravity))
                        .foregroundStyle(
                            gravityDiffers ? theme.warn : theme.subtle
                        )
                        .accessibilityLabel(
                            "Gravity \(Format.count(gravity))"
                                + (gravityDiffers ? ", differs" : ""))
                }
            }
            .font(.caption.monospacedDigit())
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    /// "CPU 12% · Mem 41% · 48°C · Load 3% · 4d 2h", "unreachable", or "…"
    /// before the first probe.
    private func machineStats(_ row: InstanceRow) -> String {
        if row.isUnreachable {
            return "— · — · — · unreachable"
        }
        guard let health = row.health else {
            return "…"
        }
        let sensors = health.sensors
        let temp =
            sensors.hasTemp
            ? String(
                format: "%.0f°%@", sensors.cpuTemp,
                sensors.unit.isEmpty ? "C" : sensors.unit)
            : "n/a"
        return [
            "CPU " + Format.percent(health.system.cpuPercent),
            "Mem " + Format.percent(health.system.memUsedPercent),
            temp,
            "Load " + Format.percent(health.system.load1Percent),
            Format.uptime(seconds: health.system.uptime),
        ].joined(separator: " · ")
    }

    @ViewBuilder
    private func healthLabel(_ row: InstanceRow) -> some View {
        if let health = row.health {
            if let count = health.messages {
                if count == 0 {
                    Label("Clear", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(theme.allow)
                } else {
                    Label(
                        Format.issues(count),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(theme.warn)
                }
            } else {
                Label("Unknown", systemImage: "questionmark.circle")
                    .foregroundStyle(theme.warn)
            }
        }
    }

    private func gaugeTile(_ label: String, value: String, fraction: Double)
        -> some View
    {
        let clamped = clamp(fraction)
        return Card {
            Text(label)
                .font(.caption)
                .foregroundStyle(theme.subtle)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            ProgressView(value: clamped)
                .tint(theme.healthColor(fraction: clamped))
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var temperatureTile: some View {
        if data.sensors.hasTemp {
            let unit = data.sensors.unit.isEmpty ? "C" : data.sensors.unit
            let fraction =
                data.sensors.hotLimit > 0
                ? data.sensors.cpuTemp / data.sensors.hotLimit : 0
            gaugeTile(
                "Temp",
                value: String(format: "%.0f°%@", data.sensors.cpuTemp, unit),
                fraction: fraction
            )
        } else {
            Card {
                Text("Temp")
                    .font(.caption)
                    .foregroundStyle(theme.subtle)
                Text("n/a")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.subtle)
                Text("no sensor")
                    .font(.caption2)
                    .foregroundStyle(theme.subtle)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var loadTile: some View {
        Card {
            Text("Load · Up")
                .font(.caption)
                .foregroundStyle(theme.subtle)
            Text(Format.percent(data.system.load1Percent))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(theme.text)
            Text(
                """
                \(data.system.procs) procs · \
                \(Format.uptime(seconds: data.system.uptime))
                """
            )
            .font(.caption2)
            .foregroundStyle(theme.subtle)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }

    private var diagnosticsTile: some View {
        Card {
            Text("Health")
                .font(.caption)
                .foregroundStyle(theme.subtle)
            if let error = data.messagesError {
                Label("Unknown", systemImage: "questionmark.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.warn)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(theme.subtle)
                    .lineLimit(2)
            } else if data.messages.isEmpty {
                Label("All clear", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.allow)
                Text("0 messages")
                    .font(.caption)
                    .foregroundStyle(theme.subtle)
            } else {
                Label(
                    Format.issues(data.messages.count),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.warn)
                Text(data.messages[0].plain)
                    .font(.caption)
                    .foregroundStyle(theme.block)
                    .lineLimit(3)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - History

    private var historyPoints: [HistorySeriesPoint] {
        var points: [HistorySeriesPoint] = []
        points.reserveCapacity(data.history.history.count * 2)
        for bucket in data.history.history {
            let date = Date(
                timeIntervalSince1970: TimeInterval(bucket.timestamp))
            let permitted = max(0, bucket.total - bucket.blocked)
            points.append(
                HistorySeriesPoint(
                    date: date, kind: "Permitted", count: permitted))
            points.append(
                HistorySeriesPoint(
                    date: date, kind: "Blocked", count: bucket.blocked))
        }
        return points
    }

    private var historyChart: some View {
        Card("Queries over time") {
            if let error = data.historyError {
                Text("History unavailable: \(error)")
                    .font(.footnote)
                    .foregroundStyle(theme.block)
            } else if data.history.history.isEmpty {
                Text("No history yet")
                    .font(.footnote)
                    .foregroundStyle(theme.subtle)
            } else {
                Chart(historyPoints) { point in
                    AreaMark(
                        x: .value("Time", point.date),
                        y: .value("Queries", point.count)
                    )
                    .foregroundStyle(by: .value("Kind", point.kind))
                }
                .chartForegroundStyleScale([
                    "Permitted": theme.accent,
                    "Blocked": theme.block,
                ])
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .frame(height: 150)
                .accessibilityLabel("Queries over time, permitted and blocked")
            }
        }
    }

    // MARK: - Breakdowns

    private var typeItems: [LabeledCount] {
        data.types.types
            .map { LabeledCount(label: $0.key, count: $0.value) }
            .filter { $0.count > 0 }
            .sorted { lhs, rhs in
                lhs.count != rhs.count
                    ? lhs.count > rhs.count : lhs.label < rhs.label
            }
    }

    private var upstreamItems: [LabeledCount] {
        data.upstreams.upstreams.map {
            LabeledCount(
                label: $0.name.isEmpty ? $0.ip : $0.name, count: $0.count)
        }
    }

    private func domainItems(_ top: TopDomains) -> [LabeledCount] {
        top.domains.map { LabeledCount(label: $0.domain, count: $0.count) }
    }

    private var clientItems: [LabeledCount] {
        data.topClients.clients.map {
            LabeledCount(
                label: $0.name.isEmpty ? $0.ip : $0.name, count: $0.count)
        }
    }

    private func breakdown(
        _ title: String, items: [LabeledCount], error: String?
    ) -> some View {
        topList(title, items: items, error: error, color: theme.accent)
    }

    private func topList(
        _ title: String, items: [LabeledCount], error: String?, color: Color
    ) -> some View {
        let largest = max(items.map(\.count).max() ?? 0, 1)
        return Card(title) {
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(theme.block)
            } else if items.isEmpty {
                Text("No data")
                    .font(.footnote)
                    .foregroundStyle(theme.subtle)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    BreakdownRow(
                        label: item.label,
                        count: item.count,
                        fraction: Double(item.count) / Double(largest),
                        color: color
                    )
                }
            }
        }
    }

    private func clamp(_ fraction: Double) -> Double {
        if fraction.isNaN {
            return 0
        }
        return min(max(fraction, 0), 1)
    }

    // MARK: - Loading

    @MainActor
    private func refresh(force: Bool = false) async {
        guard app.canRead, app.isForeground else {
            return
        }
        // Nil in combined mode when the active Pi-hole is misconfigured; the
        // merged panels still load and the per-machine ones report why.
        let active = app.client
        let problem = app.connectionProblem ?? "No active instance"
        let client: @Sendable () throws -> PiholeClient = {
            guard let active else {
                throw ConfigProblem(messages: [problem])
            }
            return active
        }
        let startedAt = app.generation
        let count = topCount
        let slow =
            force || Date().timeIntervalSince(slowFetchedAt) >= slowInterval
        let combined = app.combinedClient

        // In combined mode one summary request per Pi-hole also yields each
        // one's gravity for the per-instance rows.
        async let summary = capture {
            if let combined {
                let both = try await combined.summaryByMember()
                return (
                    both.merged,
                    both.perMember.mapValues(\.gravity.domainsBeingBlocked)
                )
            }
            return (
                Combined(value: try await client().summary()), [String: Int]()
            )
        }
        async let history = capture(if: slow) {
            try await readStats(combined, { try await $0.history() }) {
                try await client().history()
            }
        }
        async let types = capture {
            try await readStats(combined, { try await $0.queryTypes() }) {
                try await client().queryTypes()
            }
        }
        async let upstreams = capture {
            try await readStats(combined, { try await $0.upstreams() }) {
                try await client().upstreams()
            }
        }
        async let topDomains = capture {
            try await readStats(
                combined,
                { try await $0.topDomains(blocked: false, count: count) }
            ) {
                try await client().topDomains(blocked: false, count: count)
            }
        }
        async let topBlocked = capture {
            try await readStats(
                combined,
                { try await $0.topDomains(blocked: true, count: count) }
            ) {
                try await client().topDomains(blocked: true, count: count)
            }
        }
        async let topClients = capture {
            try await readStats(
                combined,
                { try await $0.topClients(blocked: false, count: count) }
            ) {
                try await client().topClients(blocked: false, count: count)
            }
        }
        async let system = capture { try await client().system() }
        async let sensors = capture(if: slow) { try await client().sensors() }
        async let messages = capture(if: slow) { try await client().messages() }
        // The other Pi-holes' machine stats; the active row reuses the
        // fetches above.
        async let probes = capture(if: slow && combined != nil) {
            guard let combined else {
                throw CancellationError()
            }
            return try await combined.eachMember(except: active) { member in
                async let system = member.system()
                async let sensors = try? member.sensors()
                async let messages = try? member.messages()
                return MemberHealth(
                    system: try await system,
                    sensors: await sensors ?? Sensors(),
                    messages: await messages?.count)
            }
        }

        let summaryResult = await summary
        let historyResult = await history
        let typesResult = await types
        let upstreamsResult = await upstreams
        let topDomainsResult = await topDomains
        let topBlockedResult = await topBlocked
        let topClientsResult = await topClients
        let systemResult = await system
        let sensorsResult = await sensors
        let messagesResult = await messages
        let probesResult = await probes

        // The instance was switched, or the screen was left, mid-fetch.
        guard startedAt == app.generation, !Task.isCancelled else {
            return
        }

        var next = data
        var unreachable = Set<String>()
        merge(
            summaryResult.map { $0.0 }, into: &next.summary,
            unreachable: &unreachable, error: &next.summaryError)
        if case .success(let (_, gravity)) = summaryResult {
            next.memberGravity = gravity
        }
        if case .success(let fresh) = probesResult {
            next.memberHealth = fresh
        }
        merge(
            historyResult, into: &next.history, unreachable: &unreachable,
            error: &next.historyError)
        merge(
            typesResult, into: &next.types, unreachable: &unreachable,
            error: &next.typesError)
        merge(
            upstreamsResult, into: &next.upstreams, unreachable: &unreachable,
            error: &next.upstreamsError)
        merge(
            topDomainsResult, into: &next.topDomains,
            unreachable: &unreachable, error: &next.topDomainsError)
        merge(
            topBlockedResult, into: &next.topBlocked,
            unreachable: &unreachable, error: &next.topBlockedError)
        merge(
            topClientsResult, into: &next.topClients,
            unreachable: &unreachable, error: &next.topClientsError)
        merge(systemResult, into: &next.system, error: &next.systemError)
        merge(messagesResult, into: &next.messages, error: &next.messagesError)
        // A host without sensors is normal, so a sensors failure is not shown.
        if case .success(let fresh) = sensorsResult {
            next.sensors = fresh
        }
        next.unreachable = unreachable.sorted()
        next.loaded = true
        data = next
        if slow {
            slowFetchedAt = Date()
        }

        offerHotLimitIfNeeded()
    }

    /// Like `merge`, for a possibly combined result: also collects the
    /// Pi-holes it is missing.
    private func merge<T: Sendable>(
        _ result: Result<Combined<T>, Error>, into value: inout T,
        unreachable: inout Set<String>, error: inout String?
    ) {
        if case .success(let fresh) = result {
            unreachable.formUnion(fresh.failed)
        }
        merge(result.map(\.value), into: &value, error: &error)
    }

    private func merge<T>(
        _ result: Result<T, Error>, into value: inout T, error: inout String?
    ) {
        switch result {
        case .success(let fresh):
            value = fresh
            error = nil
        case .failure(let failure):
            if !ErrorText.isCancellation(failure) {
                error = ErrorText.describe(failure)
            }
        }
    }

    // MARK: - Hot-temperature prompt

    /// Offers, once per instance per launch, to raise Pi-hole's stock 60°C
    /// threshold, which reads as "hot" on boards that idle near it.
    private func offerHotLimitIfNeeded() {
        guard !hotLimitPrompted,
            data.sensors.hasTemp,
            data.sensors.unit == "C",
            data.sensors.hotLimit == hotLimitDefault
        else {
            return
        }
        hotLimitPrompted = true
        showingHotLimitPrompt = true
    }

    @MainActor
    private func raiseHotLimit() async {
        guard let client = app.client else {
            return
        }
        do {
            try await client.patchConfig(
                ConfigTree.patch(
                    path: "misc.temp.limit", value: .number(hotLimitSuggested)),
                restart: false
            )
            actionError = nil
            await refresh(force: true)
        } catch {
            if !ErrorText.isCancellation(error) {
                actionError = ErrorText.describe(error)
            }
        }
    }
}

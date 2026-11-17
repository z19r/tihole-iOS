import Charts
import PiholeKit
import SwiftUI
import TiholeCore

/// Runs `operation` and returns its outcome as a value, so several fetches
/// can run side by side and each fail on its own.
func capture<T>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
    do {
        return .success(try await operation())
    } catch {
        return .failure(error)
    }
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

    /// Rows shown in each top-N panel.
    private let topCount = 8
    /// Seconds between refreshes while the dashboard is on screen.
    private let pollInterval = 3.0
    /// Pi-hole's stock hot-temperature threshold, and the one offered instead.
    private let hotLimitDefault = 60.0
    private let hotLimitSuggested = 85.0

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let problem = app.connectionProblem {
                    ErrorBanner(message: problem)
                }
                if let actionError {
                    ErrorBanner(message: actionError)
                }

                if !data.loaded && app.client != nil {
                    ProgressView("Loading dashboard…")
                        .tint(theme.accent)
                        .foregroundStyle(theme.subtle)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    tiles
                    health
                    historyChart
                    breakdown("Query Types", items: typeItems, error: data.typesError)
                    breakdown("Upstreams", items: upstreamItems, error: data.upstreamsError)
                    topList("Top Domains", items: domainItems(data.topDomains), error: data.topDomainsError, color: theme.accent)
                    topList("Top Blocked", items: domainItems(data.topBlocked), error: data.topBlockedError, color: theme.block)
                    topList("Top Clients", items: clientItems, error: data.topClientsError, color: theme.accent)
                }
            }
            .padding(12)
        }
        .screenStyle()
        .navigationTitle("Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        .chrome()
        .refreshable {
            await refresh()
        }
        .task(id: app.generation) {
            data = DashboardData()
            hotLimitPrompted = false
            actionError = nil
            await repeatEvery(pollInterval) {
                await refresh()
            }
        }
        .alert("Raise hot-temperature threshold?", isPresented: $showingHotLimitPrompt) {
            Button("Raise to 85°C") {
                Task {
                    await raiseHotLimit()
                }
            }
            Button("Keep 60°C", role: .cancel) {}
        } message: {
            Text("Pi-hole's hot-temperature threshold is 60°C, but most single-board computers idle at 45 to 60°C and reach 60 to 70°C under normal load, so 60°C trips false \"hot\" warnings on the health gauge. 85°C is closer to where these CPUs actually throttle.")
        }
    }

    // MARK: - Tiles

    private var tiles: some View {
        VStack(spacing: 10) {
            if let error = data.summaryError {
                ErrorBanner(message: "Summary unavailable: \(error)")
            }
            LazyVGrid(columns: columns, spacing: 10) {
                statTile("Total Queries", value: Format.count(data.summary.queries.total))
                blockedTile
                statTile("Active Clients", value: Format.count(data.summary.clients.active))
                statTile("Gravity Domains", value: Format.count(data.summary.gravity.domainsBeingBlocked))
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
            ProgressView(value: clamp(data.summary.queries.percentBlocked / 100))
                .tint(theme.accent)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Health

    private var health: some View {
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
                diagnosticsTile
            }
        }
    }

    private func gaugeTile(_ label: String, value: String, fraction: Double) -> some View {
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
            let fraction = data.sensors.hotLimit > 0 ? data.sensors.cpuTemp / data.sensors.hotLimit : 0
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
            Text("\(data.system.procs) procs · \(Format.uptime(seconds: data.system.uptime))")
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
                Label(Format.issues(data.messages.count), systemImage: "exclamationmark.triangle.fill")
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
            let date = Date(timeIntervalSince1970: TimeInterval(bucket.timestamp))
            let permitted = max(0, bucket.total - bucket.blocked)
            points.append(HistorySeriesPoint(date: date, kind: "Permitted", count: permitted))
            points.append(HistorySeriesPoint(date: date, kind: "Blocked", count: bucket.blocked))
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
                lhs.count != rhs.count ? lhs.count > rhs.count : lhs.label < rhs.label
            }
    }

    private var upstreamItems: [LabeledCount] {
        data.upstreams.upstreams.map {
            LabeledCount(label: $0.name.isEmpty ? $0.ip : $0.name, count: $0.count)
        }
    }

    private func domainItems(_ top: TopDomains) -> [LabeledCount] {
        top.domains.map { LabeledCount(label: $0.domain, count: $0.count) }
    }

    private var clientItems: [LabeledCount] {
        data.topClients.clients.map {
            LabeledCount(label: $0.name.isEmpty ? $0.ip : $0.name, count: $0.count)
        }
    }

    private func breakdown(_ title: String, items: [LabeledCount], error: String?) -> some View {
        topList(title, items: items, error: error, color: theme.accent)
    }

    private func topList(_ title: String, items: [LabeledCount], error: String?, color: Color) -> some View {
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
    private func refresh() async {
        guard let client = app.client, app.isForeground else {
            return
        }
        let startedAt = app.generation
        let count = topCount

        async let summary = capture { try await client.summary() }
        async let history = capture { try await client.history() }
        async let types = capture { try await client.queryTypes() }
        async let upstreams = capture { try await client.upstreams() }
        async let topDomains = capture { try await client.topDomains(blocked: false, count: count) }
        async let topBlocked = capture { try await client.topDomains(blocked: true, count: count) }
        async let topClients = capture { try await client.topClients(blocked: false, count: count) }
        async let system = capture { try await client.system() }
        async let sensors = capture { try await client.sensors() }
        async let messages = capture { try await client.messages() }

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

        // The instance was switched, or the screen was left, mid-fetch.
        guard startedAt == app.generation, !Task.isCancelled else {
            return
        }

        var next = data
        merge(summaryResult, into: &next.summary, error: &next.summaryError)
        merge(historyResult, into: &next.history, error: &next.historyError)
        merge(typesResult, into: &next.types, error: &next.typesError)
        merge(upstreamsResult, into: &next.upstreams, error: &next.upstreamsError)
        merge(topDomainsResult, into: &next.topDomains, error: &next.topDomainsError)
        merge(topBlockedResult, into: &next.topBlocked, error: &next.topBlockedError)
        merge(topClientsResult, into: &next.topClients, error: &next.topClientsError)
        merge(systemResult, into: &next.system, error: &next.systemError)
        merge(messagesResult, into: &next.messages, error: &next.messagesError)
        // A host without sensors is normal, so a sensors failure is not shown.
        if case .success(let fresh) = sensorsResult {
            next.sensors = fresh
        }
        next.loaded = true
        data = next

        offerHotLimitIfNeeded()
    }

    private func merge<T>(_ result: Result<T, Error>, into value: inout T, error: inout String?) {
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
                ConfigTree.patch(path: "misc.temp.limit", value: .number(hotLimitSuggested)),
                restart: false
            )
            actionError = nil
            await refresh()
        } catch {
            if !ErrorText.isCancellation(error) {
                actionError = ErrorText.describe(error)
            }
        }
    }
}

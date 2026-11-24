import PiholeKit
import SwiftUI
import TiholeCore

/// What the query-log task depends on. Changing any field restarts loading.
private struct QueryLogKey: Hashable {
    let generation: Int
    let domain: String
    let live: Bool
}

/// The live DNS query log: newest queries first, filterable by domain, with
/// one-swipe allow and block.
struct QueryLogView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    @State private var queries: [DNSQuery] = []
    @State private var shown = 0
    @State private var total = 0
    @State private var load = LoadState()
    /// Pi-holes missing from the last combined page.
    @State private var unreachable: [String] = []

    @State private var searchText = ""
    @State private var filterDomain = ""
    @State private var isLive = true

    @State private var selected: DNSQuery?
    @State private var pending: PendingClassification?
    @State private var note: String?
    @State private var noteToken = 0

    private let pageSize = 100
    private let pollInterval = 2.0

    var body: some View {
        List {
            BannerSection(
                error: load.error ?? app.connectionProblem ?? unreachableText,
                note: note)

            Section {
                if queries.isEmpty {
                    emptyRow
                } else {
                    // Row ids repeat across Pi-holes, so key by both.
                    ForEach(queries, id: \.rowKey) { query in
                        Button {
                            selected = query
                        } label: {
                            QueryRow(query: query)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                pending = PendingClassification(
                                    type: .deny, domain: query.domain)
                            } label: {
                                Label("Block", systemImage: "hand.raised.fill")
                            }
                            .tint(theme.block)

                            Button {
                                pending = PendingClassification(
                                    type: .allow, domain: query.domain)
                            } label: {
                                Label(
                                    "Allow",
                                    systemImage: "checkmark.shield.fill")
                            }
                            .tint(theme.allow)
                        }
                    }
                }
            } header: {
                Text(
                    """
                    \(Format.count(shown)) shown · \(Format.count(total)) total
                    """
                )
                .foregroundStyle(theme.subtle)
            }
            .rowStyle()
        }
        .screenStyle()
        .navigationTitle("Query Log")
        .navigationBarTitleDisplayMode(.inline)
        .chrome(readsCombined: true)
        .searchable(text: $searchText, prompt: "Filter by domain")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onSubmit(of: .search) {
            filterDomain = searchText.trimmingCharacters(
                in: .whitespacesAndNewlines)
        }
        .onChange(of: searchText) { _, value in
            if value.isEmpty {
                filterDomain = ""
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isLive.toggle()
                } label: {
                    Image(systemName: isLive ? "pause.circle" : "play.circle")
                }
                .accessibilityLabel(
                    isLive ? "Pause live updates" : "Resume live updates")
            }
        }
        .refreshable {
            await fetch(force: true)
        }
        .task(
            id: QueryLogKey(
                generation: app.generation, domain: filterDomain, live: isLive)
        ) {
            if isLive {
                await repeatEvery(pollInterval) {
                    await fetch(force: false)
                }
            } else {
                await fetch(force: true)
            }
        }
        .onChange(of: app.generation) { _, _ in
            queries = []
            shown = 0
            total = 0
            unreachable = []
            load = LoadState()
        }
        .sheet(item: $selected) { query in
            QueryDetailSheet(query: query) { type in
                await classify(type: type, domain: query.domain)
            }
        }
        .alert(
            pending?.type == .deny ? "Block domain?" : "Allow domain?",
            isPresented: pendingBinding,
            presenting: pending
        ) { item in
            Button(item.type == .deny ? "Block" : "Allow") {
                Task {
                    await classify(type: item.type, domain: item.domain)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(item.domain + writeTarget)
        }
    }

    /// In combined mode, where allow and block land.
    private var writeTarget: String {
        guard app.isCombined, let name = app.activeInstance?.name else {
            return ""
        }
        return " on \(name)"
    }

    private var unreachableText: String? {
        unreachable.isEmpty
            ? nil
            : "Not reachable: \(unreachable.joined(separator: ", ")). "
                + "Showing the rest."
    }

    private var pendingBinding: Binding<Bool> {
        Binding(
            get: { pending != nil },
            set: { isPresented in
                if !isPresented {
                    pending = nil
                }
            }
        )
    }

    @ViewBuilder
    private var emptyRow: some View {
        if load.isLoading && !load.hasLoaded {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading queries…")
                    .foregroundStyle(theme.subtle)
            }
        } else {
            Text("No queries match this filter")
                .foregroundStyle(theme.subtle)
        }
    }

    // MARK: - Loading

    /// Fetches the newest page. Polls (`force` false) are skipped while a
    /// detail sheet or confirmation is up, so rows do not move underneath it.
    @MainActor
    private func fetch(force: Bool) async {
        guard let client = app.client, app.isForeground else {
            return
        }
        if !force && (selected != nil || pending != nil) {
            return
        }
        let startedAt = app.generation
        var filter = QueryFilter(length: pageSize)
        if !filterDomain.isEmpty {
            filter.domain = filterDomain
        }

        let combined = app.isCombined ? app.combinedClient : nil

        load.begin()
        do {
            let result =
                if let combined {
                    try await combined.queries(filter)
                } else {
                    Combined(value: try await client.queries(filter))
                }
            guard startedAt == app.generation else {
                return
            }
            let page = result.value
            unreachable = result.failed
            queries = page.queries
            shown = page.recordsFiltered
            total = page.recordsTotal
            load.succeed()
        } catch {
            load.fail(error)
        }
    }

    /// Adds `domain` to the exact allow or deny list in the default group.
    @MainActor
    private func classify(type: DomainType, domain: String) async {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client = app.client, !trimmed.isEmpty else {
            return
        }
        do {
            try await client.addDomain(
                type: type,
                kind: .exact,
                domain: trimmed,
                comment: "added from query log (tihole)",
                groups: [0]
            )
            load.error = nil
            showNote(
                (type == .deny ? "Blocked " : "Allowed ") + trimmed
                    + writeTarget)
        } catch {
            load.fail(error)
        }
    }

    /// Shows a success note for a few seconds.
    private func showNote(_ text: String) {
        note = text
        noteToken += 1
        let token = noteToken
        Task {
            try? await Task.sleep(for: .seconds(4))
            if token == noteToken {
                note = nil
            }
        }
    }
}

/// A domain waiting on the allow/block confirmation.
private struct PendingClassification: Identifiable {
    let id = UUID()
    let type: DomainType
    let domain: String
}

extension DNSQuery {
    fileprivate var rowKey: String { "\(instance)/\(id)" }
}

private func clientLabel(_ client: DNSQuery.Client) -> String {
    client.name.trimmingCharacters(in: .whitespaces).isEmpty
        ? client.ip : client.name
}

private struct QueryRow: View {
    @Environment(\.theme) private var theme
    let query: DNSQuery

    var body: some View {
        let tone = QueryStatus.tone(query.status)

        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(query.domain)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(theme.color(for: tone))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(
                    ([query.instance, clientLabel(query.client), query.type])
                        .filter { !$0.isEmpty }
                        .joined(separator: " · ")
                )
                .font(.caption)
                .foregroundStyle(theme.subtle)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(Format.clock(query.time))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.subtle)
                Badge(
                    text: query.status.isEmpty ? "-" : query.status,
                    color: tone == .neutral
                        ? theme.subtle : theme.color(for: tone)
                )
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Every field of one query, with allow and block actions.
private struct QueryDetailSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let query: DNSQuery
    /// Adds the query's domain to the allow or deny list.
    let classify: (DomainType) async -> Void

    @State private var confirming: DomainType?

    var body: some View {
        let toneColor = theme.color(for: QueryStatus.tone(query.status))

        NavigationStack {
            List {
                Section {
                    DetailRow(
                        label: "Domain", value: query.domain,
                        valueColor: toneColor, monospaced: true)
                    DetailRow(
                        label: "CNAME", value: Format.orDash(query.cname),
                        monospaced: true)
                    DetailRow(label: "Client", value: clientDetail)
                    DetailRow(label: "Type", value: Format.orDash(query.type))
                    DetailRow(
                        label: "Status", value: Format.orDash(query.status),
                        valueColor: toneColor)
                    DetailRow(label: "Reply", value: replyDetail)
                    DetailRow(
                        label: "Upstream", value: Format.orDash(query.upstream))
                    DetailRow(
                        label: "DNSSEC", value: Format.orDash(query.dnssec))
                    DetailRow(label: "Time", value: Format.clock(query.time))
                    if !query.instance.isEmpty {
                        DetailRow(label: "Pi-hole", value: query.instance)
                    }
                }
                .rowStyle()

                Section {
                    Button {
                        confirming = .allow
                    } label: {
                        Label(
                            "Allow this domain",
                            systemImage: "checkmark.shield.fill"
                        )
                        .foregroundStyle(theme.allow)
                    }
                    Button {
                        confirming = .deny
                    } label: {
                        Label(
                            "Block this domain", systemImage: "hand.raised.fill"
                        )
                        .foregroundStyle(theme.block)
                    }
                }
                .rowStyle()
            }
            .screenStyle()
            .navigationTitle("Query detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                confirming == .deny
                    ? "Block \(query.domain)?" : "Allow \(query.domain)?",
                isPresented: confirmingBinding,
                titleVisibility: .visible,
                presenting: confirming
            ) { type in
                Button(type == .deny ? "Block" : "Allow") {
                    Task {
                        await classify(type)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var confirmingBinding: Binding<Bool> {
        Binding(
            get: { confirming != nil },
            set: { isPresented in
                if !isPresented {
                    confirming = nil
                }
            }
        )
    }

    private var clientDetail: String {
        let name = query.client.name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? query.client.ip : "\(name) (\(query.client.ip))"
    }

    private var replyDetail: String {
        String(
            format: "%@ (%.1f ms)", Format.orDash(query.reply.type),
            query.reply.time * 1000)
    }
}

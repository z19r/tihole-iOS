import PiholeKit
import SwiftUI
import TiholeCore

/// The System tab: host and FTL info, diagnosis messages, the network device
/// table, a live DNS log tail, and guarded destructive actions.
struct SystemView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    @State private var messageCount = 0

    var body: some View {
        List {
            BannerSection(error: app.connectionProblem)

            Section {
                NavigationLink {
                    SystemInfoView()
                } label: {
                    row("Info", detail: "FTL, host, system, and version details", icon: "info.circle")
                }
                NavigationLink {
                    MessagesView()
                } label: {
                    HStack {
                        row("Messages", detail: "Diagnosis messages from FTL", icon: "exclamationmark.bubble")
                        Spacer()
                        if messageCount > 0 {
                            Badge(text: "\(messageCount)", color: theme.warn)
                        }
                    }
                }
                NavigationLink {
                    NetworkView()
                } label: {
                    row("Network", detail: "Devices FTL has seen on the network", icon: "network")
                }
                NavigationLink {
                    LogTailView()
                } label: {
                    row("Log tail", detail: "Live DNS resolver log", icon: "text.alignleft")
                }
            }
            .rowStyle()

            Section {
                NavigationLink {
                    ActionsView()
                } label: {
                    row("Actions", detail: "Restart DNS, flush logs, flush network", icon: "bolt.trianglebadge.exclamationmark")
                }
            }
            .rowStyle()
        }
        .screenStyle()
        .navigationTitle("System")
        .navigationBarTitleDisplayMode(.inline)
        .chrome()
        .task(id: app.generation) {
            messageCount = 0
            await loadMessageCount()
        }
        .refreshable {
            await loadMessageCount()
        }
    }

    private func row(_ title: String, detail: String, icon: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(theme.text)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(theme.subtle)
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(theme.accent)
        }
    }

    @MainActor
    private func loadMessageCount() async {
        guard let client = app.client else {
            return
        }
        if let count = try? await client.messageCount() {
            messageCount = count
        }
    }
}

// MARK: - Info

private struct InfoSection: Identifiable {
    let name: String
    let rows: [InfoRows.Row]
    var id: String { name }
}

/// FTL, host, system, and version details, flattened to key/value rows.
struct SystemInfoView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    @State private var sections: [InfoSection] = []
    @State private var load = LoadState()

    private let sectionNames = ["ftl", "host", "system", "version"]

    var body: some View {
        List {
            BannerSection(error: load.error ?? app.connectionProblem)

            if sections.isEmpty {
                Section {
                    ListPlaceholder(load: load, loadingText: "Loading info…", emptyText: "No info available")
                }
                .rowStyle()
            } else {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            DetailRow(label: row.key, value: row.value, monospaced: true)
                                .font(.footnote)
                        }
                    } header: {
                        Text(section.name)
                            .foregroundStyle(theme.accent)
                    }
                    .rowStyle()
                }
            }
        }
        .screenStyle()
        .navigationTitle("Info")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await reload()
        }
        .task(id: app.generation) {
            sections = []
            load = LoadState()
            await reload()
        }
    }

    /// Loads each section in turn. One failing section is reported but does
    /// not hide the others.
    @MainActor
    private func reload() async {
        guard let client = app.client else {
            return
        }
        load.begin()
        var fetched: [InfoSection] = []
        var firstError: Error?
        for name in sectionNames {
            do {
                let info = try await client.info(name)
                fetched.append(InfoSection(name: name, rows: InfoRows.flatten(info)))
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if !fetched.isEmpty || firstError == nil {
            sections = fetched
        }
        if let firstError {
            load.fail(firstError)
        } else {
            load.succeed()
        }
    }
}

// MARK: - Messages

/// FTL's diagnosis messages, dismissable one at a time or all at once.
struct MessagesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    @State private var messages: [DiagnosisMessage] = []
    @State private var load = LoadState()
    @State private var confirmingDismissAll = false

    var body: some View {
        List {
            BannerSection(error: load.error ?? app.connectionProblem)

            Section {
                if messages.isEmpty {
                    ListPlaceholder(load: load, loadingText: "Loading messages…", emptyText: "No diagnosis messages")
                } else {
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Badge(text: message.type.isEmpty ? "message" : message.type, color: theme.warn)
                                Spacer()
                                Text(Format.shortDateTime(Int64(message.timestamp)))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(theme.subtle)
                            }
                            Text(message.plain)
                                .font(.footnote)
                                .foregroundStyle(theme.text)
                                .textSelection(.enabled)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                Task {
                                    await dismiss(ids: [message.id])
                                }
                            } label: {
                                Label("Dismiss", systemImage: "xmark.circle")
                            }
                            .tint(theme.block)
                        }
                    }
                }
            }
            .rowStyle()
        }
        .screenStyle()
        .navigationTitle("Messages")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Dismiss all") {
                    confirmingDismissAll = true
                }
                .disabled(messages.isEmpty)
            }
        }
        .refreshable {
            await reload()
        }
        .task(id: app.generation) {
            messages = []
            load = LoadState()
            await reload()
        }
        .confirmationDialog(
            "Dismiss all messages?",
            isPresented: $confirmingDismissAll,
            titleVisibility: .visible
        ) {
            Button("Dismiss \(messages.count)", role: .destructive) {
                let ids = messages.map(\.id)
                Task {
                    await dismiss(ids: ids)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @MainActor
    private func reload() async {
        guard let client = app.client else {
            return
        }
        load.begin()
        do {
            messages = try await client.messages()
            load.succeed()
        } catch {
            load.fail(error)
        }
    }

    @MainActor
    private func dismiss(ids: [Int]) async {
        guard let client = app.client else {
            return
        }
        do {
            try await client.deleteMessages(ids: ids)
            await reload()
        } catch {
            load.fail(error)
        }
    }
}

// MARK: - Network

/// Every device FTL has seen, with its addresses and query count.
struct NetworkView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    @State private var devices: [NetworkDevice] = []
    @State private var load = LoadState()
    @State private var deleting: NetworkDevice?

    var body: some View {
        List {
            BannerSection(error: load.error ?? app.connectionProblem)

            Section {
                if devices.isEmpty {
                    ListPlaceholder(load: load, loadingText: "Loading devices…", emptyText: "No network devices")
                } else {
                    ForEach(devices) { device in
                        NetworkDeviceRow(device: device)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    deleting = device
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(theme.block)
                            }
                    }
                }
            } header: {
                Text(devices.count == 1 ? "1 device" : "\(devices.count) devices")
                    .foregroundStyle(theme.subtle)
            }
            .rowStyle()
        }
        .screenStyle()
        .navigationTitle("Network")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await reload()
        }
        .task(id: app.generation) {
            devices = []
            load = LoadState()
            await reload()
        }
        .confirmationDialog(
            "Delete device?",
            isPresented: $deleting.isPresent(),
            titleVisibility: .visible,
            presenting: deleting
        ) { device in
            Button("Delete", role: .destructive) {
                Task {
                    await delete(device)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { device in
            Text("\(device.ips.first?.ip ?? "-") · \(device.hwaddr)")
        }
    }

    @MainActor
    private func reload() async {
        guard let client = app.client else {
            return
        }
        load.begin()
        do {
            devices = try await client.networkDevices()
            load.succeed()
        } catch {
            load.fail(error)
        }
    }

    @MainActor
    private func delete(_ device: NetworkDevice) async {
        guard let client = app.client else {
            return
        }
        do {
            try await client.deleteNetworkDevice(id: device.id)
            await reload()
        } catch {
            load.fail(error, destructive: true)
        }
    }
}

private struct NetworkDeviceRow: View {
    @Environment(\.theme) private var theme
    let device: NetworkDevice

    private var title: String {
        if let name = device.ips.first(where: { !$0.name.isEmpty })?.name {
            return name
        }
        return device.ips.first?.ip ?? device.hwaddr
    }

    private var addresses: String {
        let ips = device.ips.map(\.ip).filter { !$0.isEmpty }
        return ips.isEmpty ? "-" : ips.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(Format.count(device.numQueries)) queries")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.subtle)
            }
            Text(addresses)
                .font(.caption.monospaced())
                .foregroundStyle(theme.accent)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(device.hwaddr)
                    .font(.caption2.monospaced())
                if !device.macVendor.isEmpty {
                    Text("· \(device.macVendor)")
                        .font(.caption2)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if device.lastQuery > 0 {
                    Text("last \(Format.shortDateTime(device.lastQuery))")
                        .font(.caption2.monospacedDigit())
                }
            }
            .foregroundStyle(theme.subtle)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Log tail

private struct LogEntry: Identifiable {
    let id: Int
    let text: String
}

/// A live tail of the DNS resolver log, polled from FTL's log cursor.
struct LogTailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    @State private var entries: [LogEntry] = []
    @State private var nextID = 0
    @State private var counter = 0
    @State private var load = LoadState()
    @State private var following = true

    /// Lines kept in memory; older ones are dropped.
    private let maxLines = 2000
    private let pollInterval = 2.0
    private let bottomID = "log-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = load.error ?? app.connectionProblem {
                ErrorBanner(message: error)
                    .padding(12)
            }

            if entries.isEmpty {
                VStack(spacing: 10) {
                    if load.isLoading && !load.hasLoaded {
                        ProgressView()
                        Text("Reading log…")
                    } else {
                        Text("Waiting for log lines…")
                    }
                }
                .foregroundStyle(theme.subtle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(entries) { entry in
                                Text(entry.text)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(theme.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(bottomID)
                        }
                        .padding(12)
                    }
                    .onChange(of: counter) { _, _ in
                        if following {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    }
                    .onChange(of: following) { _, isFollowing in
                        if isFollowing {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(theme.surface.ignoresSafeArea())
        .toolbarBackground(theme.panel, for: .navigationBar, .tabBar)
        .toolbarBackground(.visible, for: .navigationBar, .tabBar)
        .navigationTitle("Log tail")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    following.toggle()
                } label: {
                    Image(systemName: following ? "arrow.down.to.line.circle.fill" : "arrow.down.to.line.circle")
                }
                .accessibilityLabel(following ? "Stop following new lines" : "Follow new lines")
            }
        }
        .task(id: app.generation) {
            entries = []
            nextID = 0
            load = LoadState()
            await repeatEvery(pollInterval) {
                await fetch()
            }
        }
    }

    @MainActor
    private func fetch() async {
        guard let client = app.client, app.isForeground else {
            return
        }
        let startedAt = app.generation
        load.begin()
        do {
            let page = try await client.dnsLog(nextID: nextID)
            guard startedAt == app.generation else {
                return
            }
            append(page)
            load.succeed()
        } catch {
            load.fail(error)
        }
    }

    private func append(_ page: DNSLogPage) {
        if page.nextID > 0 {
            nextID = page.nextID
        }
        if page.log.isEmpty {
            return
        }
        var updated = entries
        var next = counter
        for line in page.log {
            next += 1
            let message = line.message.trimmingCharacters(in: .newlines)
            updated.append(LogEntry(id: next, text: Format.clock(line.timestamp) + "  " + message))
        }
        if updated.count > maxLines {
            updated.removeFirst(updated.count - maxLines)
        }
        entries = updated
        counter = next
    }
}

// MARK: - Actions

private struct SystemAction: Identifiable {
    let id: String
    let label: String
    let detail: String
    let icon: String
    let perform: (PiholeClient) async throws -> Void
}

/// Destructive maintenance actions. Each needs confirmation, and FTL refuses
/// them unless `webserver.api.allow_destructive` is enabled.
struct ActionsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    @State private var load = LoadState()
    @State private var note: String?
    @State private var pending: SystemAction?

    private let actions = [
        SystemAction(
            id: "restartdns",
            label: "Restart DNS",
            detail: "Restart the FTL DNS resolver. Brief resolution outage.",
            icon: "arrow.clockwise.circle",
            perform: { try await $0.restartDNS() }
        ),
        SystemAction(
            id: "flush-logs",
            label: "Flush logs",
            detail: "Permanently clear the FTL query log.",
            icon: "trash.circle",
            perform: { try await $0.flushLogs() }
        ),
        SystemAction(
            id: "flush-network",
            label: "Flush network",
            detail: "Permanently clear the FTL network device table.",
            icon: "xmark.circle",
            perform: { try await $0.flushNetwork() }
        ),
    ]

    var body: some View {
        List {
            BannerSection(error: load.error ?? app.connectionProblem, note: note)

            Section {
                ForEach(actions) { action in
                    Button {
                        pending = action
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.label)
                                    .foregroundStyle(theme.block)
                                Text(action.detail)
                                    .font(.caption)
                                    .foregroundStyle(theme.subtle)
                            }
                        } icon: {
                            Image(systemName: action.icon)
                                .foregroundStyle(theme.block)
                        }
                    }
                    .disabled(load.isLoading || app.client == nil)
                }
            } header: {
                Text("Destructive actions")
            } footer: {
                Text("These may require webserver.api.allow_destructive in the Pi-hole configuration.")
                    .foregroundStyle(theme.subtle)
            }
            .rowStyle()
        }
        .screenStyle()
        .navigationTitle("Actions")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            pending.map { $0.label + "?" } ?? "Run action?",
            isPresented: $pending.isPresent(),
            titleVisibility: .visible,
            presenting: pending
        ) { action in
            Button(action.label, role: .destructive) {
                Task {
                    await run(action)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action.detail)
        }
    }

    @MainActor
    private func run(_ action: SystemAction) async {
        guard let client = app.client else {
            return
        }
        note = nil
        load.begin()
        do {
            try await action.perform(client)
            load.succeed()
            note = action.label + " done"
        } catch {
            load.fail(error, destructive: true)
        }
    }
}

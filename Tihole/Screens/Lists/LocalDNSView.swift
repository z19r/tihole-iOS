import PiholeKit
import SwiftUI
import TiholeCore

/// The two kinds of local DNS record.
enum LocalRecordKind: String, CaseIterable, Identifiable {
    case hosts
    case cnames

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hosts: return "Hosts (A/AAAA)"
        case .cnames: return "CNAMEs"
        }
    }
}

/// A record waiting on the delete confirmation.
private enum PendingRecord: Identifiable {
    case host(HostRecord)
    case cname(CNAMERecord)

    var id: String {
        switch self {
        case .host(let record): return "host:" + record.id
        case .cname(let record): return "cname:" + record.id
        }
    }

    var title: String {
        switch self {
        case .host: return "Delete host record?"
        case .cname: return "Delete CNAME record?"
        }
    }

    var detail: String {
        switch self {
        case .host(let record): return "\(record.domain) → \(record.ip)"
        case .cname(let record): return "\(record.domain) → \(record.target)"
        }
    }
}

/// Local A/AAAA host records and CNAME records. FTL stores each as a string
/// in its config, so records are added and removed, never edited in place.
struct LocalDNSView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    @State private var hosts: [HostRecord] = []
    @State private var cnames: [CNAMERecord] = []
    @State private var load = LoadState()
    @State private var kind = LocalRecordKind.hosts
    @State private var adding: LocalRecordKind?
    @State private var deleting: PendingRecord?

    var body: some View {
        List {
            BannerSection(error: load.error ?? app.connectionProblem)

            Section {
                Picker("Kind", selection: $kind) {
                    ForEach(LocalRecordKind.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            Section {
                switch kind {
                case .hosts:
                    hostRows
                case .cnames:
                    cnameRows
                }
            }
            .rowStyle()
        }
        .screenStyle()
        .navigationTitle("Local DNS")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    adding = kind
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(
                    kind == .hosts ? "Add host record" : "Add CNAME record")
            }
        }
        .refreshable {
            await reload()
        }
        .task(id: app.generation) {
            hosts = []
            cnames = []
            load = LoadState()
            await reload()
        }
        .sheet(item: $adding) { addingKind in
            LocalRecordForm(kind: addingKind) {
                await reload()
            }
        }
        .confirmationDialog(
            deleting?.title ?? "Delete record?",
            isPresented: $deleting.isPresent(),
            titleVisibility: .visible,
            presenting: deleting
        ) { record in
            Button("Delete", role: .destructive) {
                Task {
                    await delete(record)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { record in
            Text(record.detail)
        }
    }

    @ViewBuilder
    private var hostRows: some View {
        if hosts.isEmpty {
            ListPlaceholder(
                load: load, loadingText: "Loading records…",
                emptyText: "No host records")
        } else {
            ForEach(hosts) { record in
                recordRow(name: record.domain, target: record.ip, extra: nil)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            deleting = .host(record)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(theme.block)
                    }
            }
        }
    }

    @ViewBuilder
    private var cnameRows: some View {
        if cnames.isEmpty {
            ListPlaceholder(
                load: load, loadingText: "Loading records…",
                emptyText: "No CNAME records")
        } else {
            ForEach(cnames) { record in
                recordRow(
                    name: record.domain,
                    target: record.target,
                    extra: record.ttl > 0 ? "TTL \(record.ttl)" : nil
                )
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        deleting = .cname(record)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(theme.block)
                }
            }
        }
    }

    private func recordRow(name: String, target: String, extra: String?)
        -> some View
    {
        VStack(alignment: .leading, spacing: 3) {
            Text(Format.orDash(name))
                .font(.callout.monospaced())
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(theme.subtle)
                Text(Format.orDash(target))
                    .font(.caption.monospaced())
                    .foregroundStyle(theme.accent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let extra {
                    Text(extra)
                        .font(.caption2)
                        .foregroundStyle(theme.subtle)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @MainActor
    private func reload() async {
        guard let client = app.client else {
            return
        }
        load.begin()
        do {
            async let hostRecords = client.hostRecords()
            async let cnameRecords = client.cnameRecords()
            let fetchedHosts = try await hostRecords
            let fetchedCNAMEs = try await cnameRecords
            hosts = fetchedHosts
            cnames = fetchedCNAMEs
            load.succeed()
        } catch {
            load.fail(error)
        }
    }

    @MainActor
    private func delete(_ record: PendingRecord) async {
        guard let client = app.client else {
            return
        }
        do {
            switch record {
            case .host(let host):
                try await client.deleteHostRecord(host)
            case .cname(let cname):
                try await client.deleteCNAMERecord(cname)
            }
            await reload()
        } catch {
            load.fail(error)
        }
    }
}

/// Add a host or CNAME record.
private struct LocalRecordForm: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let kind: LocalRecordKind
    let onSaved: () async -> Void

    @State private var first = ""
    @State private var second = ""
    @State private var ttl = ""
    @State private var error: String?
    @State private var isSaving = false

    private var trimmedFirst: String {
        first.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedSecond: String {
        second.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        FormSheet(
            title: kind == .hosts ? "Add host record" : "Add CNAME record",
            canSave: !trimmedFirst.isEmpty && !trimmedSecond.isEmpty,
            isSaving: isSaving,
            error: error,
            onSave: {
                Task {
                    await save()
                }
            }
        ) {
            Section {
                switch kind {
                case .hosts:
                    field(
                        "IP address", placeholder: "192.0.2.10 or fd00::10",
                        text: $first)
                    field("Domain", placeholder: "host.lan", text: $second)
                case .cnames:
                    field("Domain", placeholder: "alias.lan", text: $first)
                    field("Target", placeholder: "host.lan", text: $second)
                    LabeledContent("TTL") {
                        TextField("optional", text: $ttl)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            } footer: {
                if kind == .cnames {
                    Text(
                        """
                        The target must be a domain Pi-hole already knows, \
                        such as a host record or a DHCP lease.
                        """
                    )
                }
            }
            .rowStyle()
        }
    }

    private func field(
        _ label: String, placeholder: String, text: Binding<String>
    ) -> some View {
        LabeledContent(label) {
            TextField(placeholder, text: text)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .multilineTextAlignment(.trailing)
        }
    }

    @MainActor
    private func save() async {
        guard let client = app.client else {
            error = app.connectionProblem ?? "No active instance"
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            switch kind {
            case .hosts:
                try await client.addHostRecord(
                    ip: trimmedFirst, domain: trimmedSecond)
            case .cnames:
                let seconds = Int(ttl.trimmingCharacters(in: .whitespaces)) ?? 0
                try await client.addCNAMERecord(
                    domain: trimmedFirst, target: trimmedSecond, ttl: seconds)
            }
            await onSaved()
            dismiss()
        } catch {
            if !ErrorText.isCancellation(error) {
                self.error = ErrorText.describe(error)
            }
        }
    }
}

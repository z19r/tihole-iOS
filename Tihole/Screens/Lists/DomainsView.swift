import PiholeKit
import SwiftUI
import TiholeCore

/// The filter tabs of the Domains screen.
enum DomainFilter: String, CaseIterable, Identifiable {
    case all
    case allowExact
    case denyExact
    case allowRegex
    case denyRegex

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .allowExact: return "Allow · exact"
        case .denyExact: return "Deny · exact"
        case .allowRegex: return "Allow · regex"
        case .denyRegex: return "Deny · regex"
        }
    }

    /// The type and kind a new domain gets when added from this tab.
    var defaults: (type: DomainType, kind: DomainKind) {
        switch self {
        case .all, .denyExact: return (.deny, .exact)
        case .allowExact: return (.allow, .exact)
        case .allowRegex: return (.allow, .regex)
        case .denyRegex: return (.deny, .regex)
        }
    }

    func matches(_ domain: ManagedDomain) -> Bool {
        switch self {
        case .all:
            return true
        case .allowExact:
            return domain.type == "allow" && domain.kind == "exact"
        case .denyExact:
            return domain.type == "deny" && domain.kind == "exact"
        case .allowRegex:
            return domain.type == "allow" && domain.kind == "regex"
        case .denyRegex:
            return domain.type == "deny" && domain.kind == "regex"
        }
    }
}

/// What the domain sheet is editing: an existing entry, or a new one with the
/// defaults of the tab it was opened from.
struct DomainEditorItem: Identifiable {
    let id = UUID()
    let original: ManagedDomain?
    let type: DomainType
    let kind: DomainKind
}

/// Allow and deny lists across exact and regex kinds.
struct DomainsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    @State private var domains: [ManagedDomain] = []
    @State private var load = LoadState()
    @State private var filter = DomainFilter.all
    @State private var editor: DomainEditorItem?
    @State private var deleting: ManagedDomain?

    private var visible: [ManagedDomain] {
        domains.filter { filter.matches($0) }
    }

    var body: some View {
        List {
            BannerSection(error: load.error ?? app.connectionProblem)

            Section {
                Picker("Show", selection: $filter) {
                    ForEach(DomainFilter.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
            }
            .rowStyle()

            Section {
                if visible.isEmpty {
                    ListPlaceholder(
                        load: load, loadingText: "Loading domains…",
                        emptyText: "No domains here yet")
                } else {
                    ForEach(visible) { domain in
                        Button {
                            editor = DomainEditorItem(
                                original: domain,
                                type: domain.domainType,
                                kind: domain.domainKind
                            )
                        } label: {
                            DomainRow(domain: domain)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                deleting = domain
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(theme.block)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                Task {
                                    await toggle(domain)
                                }
                            } label: {
                                Label(
                                    domain.enabled ? "Disable" : "Enable",
                                    systemImage: domain.enabled
                                        ? "pause.circle" : "play.circle"
                                )
                            }
                            .tint(theme.accent)
                        }
                    }
                }
            } header: {
                Text("\(visible.count) of \(domains.count)")
                    .foregroundStyle(theme.subtle)
            }
            .rowStyle()
        }
        .screenStyle()
        .navigationTitle("Domains")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    let defaults = filter.defaults
                    editor = DomainEditorItem(
                        original: nil, type: defaults.type, kind: defaults.kind)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add domain")
            }
        }
        .refreshable {
            await reload()
        }
        .task(id: app.generation) {
            domains = []
            load = LoadState()
            await reload()
        }
        .sheet(item: $editor) { item in
            DomainForm(item: item) {
                await reload()
            }
        }
        .confirmationDialog(
            "Delete domain?",
            isPresented: $deleting.isPresent(),
            titleVisibility: .visible,
            presenting: deleting
        ) { domain in
            Button("Delete", role: .destructive) {
                Task {
                    await delete(domain)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { domain in
            Text(domain.displayName)
        }
    }

    @MainActor
    private func reload() async {
        guard let client = app.client else {
            return
        }
        load.begin()
        do {
            domains = try await client.domains()
            load.succeed()
        } catch {
            load.fail(error)
        }
    }

    @MainActor
    private func toggle(_ domain: ManagedDomain) async {
        guard let client = app.client else {
            return
        }
        do {
            try await client.updateDomain(
                type: domain.domainType,
                kind: domain.domainKind,
                domain: domain.domain,
                comment: domain.comment,
                groups: domain.groups,
                enabled: !domain.enabled
            )
            await reload()
        } catch {
            load.fail(error)
        }
    }

    @MainActor
    private func delete(_ domain: ManagedDomain) async {
        guard let client = app.client else {
            return
        }
        do {
            try await client.deleteDomain(
                type: domain.domainType,
                kind: domain.domainKind,
                domain: domain.domain
            )
            await reload()
        } catch {
            load.fail(error)
        }
    }
}

private struct DomainRow: View {
    @Environment(\.theme) private var theme
    let domain: ManagedDomain

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            EnabledDot(enabled: domain.enabled)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(domain.displayName)
                    .font(.callout.monospaced())
                    .foregroundStyle(domain.enabled ? theme.text : theme.subtle)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if !domain.comment.isEmpty {
                    Text(domain.comment)
                        .font(.caption)
                        .foregroundStyle(theme.subtle)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Badge(
                        text: domain.type,
                        color: domain.domainType == .allow
                            ? theme.allow : theme.block
                    )
                    Badge(text: domain.kind, color: theme.subtle)
                    if !domain.groups.isEmpty {
                        Text("groups \(GroupIDs.csv(domain.groups))")
                            .font(.caption2)
                            .foregroundStyle(theme.subtle)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Add or edit a domain. Type, kind, and the domain itself identify an entry
/// in FTL, so they are fixed once it exists.
private struct DomainForm: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let item: DomainEditorItem
    let onSaved: () async -> Void

    @State private var type = DomainType.deny
    @State private var kind = DomainKind.exact
    @State private var domain = ""
    @State private var comment = ""
    @State private var groups: Set<Int> = [0]
    @State private var enabled = true
    @State private var prepared = false
    @State private var error: String?
    @State private var isSaving = false

    private var isEditing: Bool { item.original != nil }

    private var trimmedDomain: String {
        domain.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        FormSheet(
            title: isEditing ? "Edit domain" : "Add domain",
            canSave: !trimmedDomain.isEmpty,
            isSaving: isSaving,
            error: error,
            onSave: {
                Task {
                    await save()
                }
            }
        ) {
            Section {
                Picker("Type", selection: $type) {
                    Text("Allow").tag(DomainType.allow)
                    Text("Deny").tag(DomainType.deny)
                }
                .pickerStyle(.segmented)
                .disabled(isEditing)

                Picker("Kind", selection: $kind) {
                    Text("Exact").tag(DomainKind.exact)
                    Text("Regex").tag(DomainKind.regex)
                }
                .pickerStyle(.segmented)
                .disabled(isEditing)
            }
            .rowStyle()

            Section {
                TextField(
                    kind == .regex ? "Regular expression" : "Domain",
                    text: $domain
                )
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(kind == .regex ? .asciiCapable : .URL)
                .disabled(isEditing)
                TextField("Comment (optional)", text: $comment)
                if isEditing {
                    Toggle("Enabled", isOn: $enabled)
                }
            }
            .rowStyle()

            GroupPickerSection(selection: $groups)
        }
        .onAppear {
            prepare()
        }
    }

    private func prepare() {
        guard !prepared else {
            return
        }
        prepared = true
        type = item.type
        kind = item.kind
        if let original = item.original {
            domain = original.domain
            comment = original.comment
            groups = Set(original.groups)
            enabled = original.enabled
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
            let commentText = comment.trimmingCharacters(
                in: .whitespacesAndNewlines)
            if let original = item.original {
                try await client.updateDomain(
                    type: original.domainType,
                    kind: original.domainKind,
                    domain: original.domain,
                    comment: commentText,
                    groups: groups.sorted(),
                    enabled: enabled
                )
            } else {
                try await client.addDomain(
                    type: type,
                    kind: kind,
                    domain: trimmedDomain,
                    comment: commentText,
                    groups: groups.sorted()
                )
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

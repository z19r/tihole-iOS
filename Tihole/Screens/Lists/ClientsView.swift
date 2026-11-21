import PiholeKit
import SwiftUI
import TiholeCore

/// What the client sheet is editing: an existing client, or a new one.
struct ClientEditorItem: Identifiable {
    let id = UUID()
    let original: ClientEntry?
}

/// Configured clients and the groups each belongs to.
struct ClientsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    @State private var clients: [ClientEntry] = []
    @State private var load = LoadState()
    @State private var editor: ClientEditorItem?
    @State private var deleting: ClientEntry?

    var body: some View {
        List {
            BannerSection(error: load.error ?? app.connectionProblem)

            Section {
                if clients.isEmpty {
                    ListPlaceholder(
                        load: load, loadingText: "Loading clients…",
                        emptyText: "No clients configured")
                } else {
                    ForEach(clients) { client in
                        Button {
                            editor = ClientEditorItem(original: client)
                        } label: {
                            ClientRow(client: client)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                deleting = client
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(theme.block)
                        }
                    }
                }
            } footer: {
                Text("Devices that are not listed here use the default group.")
                    .foregroundStyle(theme.subtle)
            }
            .rowStyle()
        }
        .screenStyle()
        .navigationTitle("Clients")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editor = ClientEditorItem(original: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add client")
            }
        }
        .refreshable {
            await reload()
        }
        .task(id: app.generation) {
            clients = []
            load = LoadState()
            await reload()
        }
        .sheet(item: $editor) { item in
            ClientForm(item: item) {
                await reload()
            }
        }
        .confirmationDialog(
            "Delete client?",
            isPresented: $deleting.isPresent(),
            titleVisibility: .visible,
            presenting: deleting
        ) { client in
            Button("Delete", role: .destructive) {
                Task {
                    await delete(client)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { client in
            Text(client.client)
        }
    }

    @MainActor
    private func reload() async {
        guard let client = app.client else {
            return
        }
        load.begin()
        do {
            clients = try await client.clients()
            load.succeed()
        } catch {
            load.fail(error)
        }
    }

    @MainActor
    private func delete(_ entry: ClientEntry) async {
        guard let client = app.client else {
            return
        }
        do {
            try await client.deleteClient(client: entry.client)
            await reload()
        } catch {
            load.fail(error)
        }
    }
}

private struct ClientRow: View {
    @Environment(\.theme) private var theme
    let client: ClientEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(client.client)
                    .font(.callout.monospaced())
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !client.name.isEmpty {
                    Text(client.name)
                        .font(.caption)
                        .foregroundStyle(theme.text)
                }
                if !client.comment.isEmpty {
                    Text(client.comment)
                        .font(.caption)
                        .foregroundStyle(theme.subtle)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text(
                client.groups.count == 1
                    ? "1 group" : "\(client.groups.count) groups"
            )
            .font(.caption)
            .foregroundStyle(theme.subtle)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The first address of a suggestion's comma- or space-separated list.
private func firstAddress(_ addresses: String) -> String {
    let trimmed = addresses.trimmingCharacters(in: .whitespacesAndNewlines)
    let first = trimmed.split(whereSeparator: { $0 == "," || $0 == " " }).first
    return first.map(String.init) ?? ""
}

/// Add or edit a client. When adding, devices FTL has seen but that are not
/// configured yet are offered as one-tap suggestions.
private struct ClientForm: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let item: ClientEditorItem
    let onSaved: () async -> Void

    @State private var client = ""
    @State private var comment = ""
    @State private var groups: Set<Int> = [0]
    @State private var prepared = false
    @State private var error: String?
    @State private var isSaving = false

    @State private var suggestions: [ClientSuggestion] = []
    @State private var suggestionsLoaded = false

    private var isEditing: Bool { item.original != nil }

    private var trimmedClient: String {
        client.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        FormSheet(
            title: isEditing ? "Edit client" : "Add client",
            canSave: !trimmedClient.isEmpty,
            isSaving: isSaving,
            error: error,
            onSave: {
                Task {
                    await save()
                }
            }
        ) {
            Section {
                TextField("IP, subnet, MAC, or hostname", text: $client)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(isEditing)
                TextField("Comment (optional)", text: $comment)
            }
            .rowStyle()

            GroupPickerSection(selection: $groups)

            if !isEditing {
                suggestionsSection
            }
        }
        .onAppear {
            guard !prepared else {
                return
            }
            prepared = true
            if let original = item.original {
                client = original.client
                comment = original.comment
                groups = Set(original.groups)
            }
        }
        .task {
            await loadSuggestions()
        }
    }

    private var suggestionsSection: some View {
        Section {
            if !suggestionsLoaded {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for unconfigured clients…")
                        .foregroundStyle(theme.subtle)
                }
            } else if suggestions.isEmpty {
                Text("No unconfigured clients seen")
                    .foregroundStyle(theme.subtle)
            } else {
                ForEach(Array(suggestions.enumerated()), id: \.offset) {
                    _, suggestion in
                    Button {
                        client = firstAddress(suggestion.addresses)
                        if comment.isEmpty {
                            comment = suggestion.name
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(
                                Format.orDash(
                                    firstAddress(suggestion.addresses))
                            )
                            .font(.callout.monospaced())
                            .foregroundStyle(theme.text)
                            Text(meta(suggestion))
                                .font(.caption)
                                .foregroundStyle(theme.subtle)
                                .lineLimit(2)
                        }
                    }
                }
            }
        } header: {
            Text("Suggestions")
        }
        .rowStyle()
    }

    private func meta(_ suggestion: ClientSuggestion) -> String {
        var parts: [String] = []
        let name = suggestion.name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            parts.append(name)
        }
        let vendor = suggestion.macVendor.trimmingCharacters(in: .whitespaces)
        if !vendor.isEmpty {
            parts.append(vendor)
        }
        if suggestion.lastQuery > 0 {
            parts.append("last " + Format.shortDateTime(suggestion.lastQuery))
        }
        if parts.isEmpty {
            return suggestion.hwaddr
        }
        return parts.joined(separator: " · ")
    }

    @MainActor
    private func loadSuggestions() async {
        guard !isEditing, let api = app.client else {
            suggestionsLoaded = true
            return
        }
        suggestions = (try? await api.clientSuggestions()) ?? []
        suggestionsLoaded = true
    }

    @MainActor
    private func save() async {
        guard let api = app.client else {
            error = app.connectionProblem ?? "No active instance"
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let commentText = comment.trimmingCharacters(
                in: .whitespacesAndNewlines)
            if let original = item.original {
                try await api.updateClient(
                    client: original.client,
                    comment: commentText,
                    groups: groups.sorted()
                )
            } else {
                try await api.addClient(
                    client: trimmedClient,
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

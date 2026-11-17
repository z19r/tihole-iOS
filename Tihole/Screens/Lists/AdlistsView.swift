import PiholeKit
import SwiftUI
import TiholeCore

/// What the adlist sheet is editing: an existing list, or a new one of the
/// type currently shown.
struct AdlistEditorItem: Identifiable {
    let id = UUID()
    let original: Adlist?
    let type: ListType
}

/// Subscribed block and allow lists, plus the gravity update that rebuilds
/// them.
struct AdlistsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    @State private var blockLists: [Adlist] = []
    @State private var allowLists: [Adlist] = []
    @State private var load = LoadState()
    @State private var shownType = ListType.block
    @State private var editor: AdlistEditorItem?
    @State private var deleting: Adlist?
    @State private var confirmingGravity = false
    @State private var showingGravity = false

    private var visible: [Adlist] {
        shownType == .block ? blockLists : allowLists
    }

    var body: some View {
        List {
            BannerSection(error: load.error ?? app.connectionProblem)

            Section {
                Picker("Type", selection: $shownType) {
                    Text("Block (\(blockLists.count))").tag(ListType.block)
                    Text("Allow (\(allowLists.count))").tag(ListType.allow)
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            Section {
                if visible.isEmpty {
                    ListPlaceholder(load: load, loadingText: "Loading lists…", emptyText: "No lists of this type")
                } else {
                    ForEach(visible) { list in
                        Button {
                            editor = AdlistEditorItem(original: list, type: list.listType)
                        } label: {
                            AdlistRow(list: list)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                deleting = list
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(theme.block)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                Task {
                                    await toggle(list)
                                }
                            } label: {
                                Label(
                                    list.enabled ? "Disable" : "Enable",
                                    systemImage: list.enabled ? "pause.circle" : "play.circle"
                                )
                            }
                            .tint(theme.accent)
                        }
                    }
                }
            } footer: {
                Text("Changes to lists take effect after a gravity update.")
                    .foregroundStyle(theme.subtle)
            }
            .rowStyle()

            Section {
                Button {
                    confirmingGravity = true
                } label: {
                    Label("Update gravity", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(app.client == nil)
            }
            .rowStyle()
        }
        .screenStyle()
        .navigationTitle("Adlists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editor = AdlistEditorItem(original: nil, type: shownType)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add list")
            }
        }
        .refreshable {
            await reload()
        }
        .task(id: app.generation) {
            blockLists = []
            allowLists = []
            load = LoadState()
            await reload()
        }
        .sheet(item: $editor) { item in
            AdlistForm(item: item) {
                await reload()
            }
        }
        .sheet(
            isPresented: $showingGravity,
            onDismiss: {
                // Gravity changes each list's domain count and status.
                Task {
                    await reload()
                }
            },
            content: {
                GravitySheet()
            }
        )
        .confirmationDialog(
            "Delete list?",
            isPresented: $deleting.isPresent(),
            titleVisibility: .visible,
            presenting: deleting
        ) { list in
            Button("Delete", role: .destructive) {
                Task {
                    await delete(list)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { list in
            Text(list.address)
        }
        .alert("Run gravity update?", isPresented: $confirmingGravity) {
            Button("Update") {
                showingGravity = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Re-download and rebuild all adlists.")
        }
    }

    @MainActor
    private func reload() async {
        guard let client = app.client else {
            return
        }
        load.begin()
        do {
            async let block = client.lists(type: .block)
            async let allow = client.lists(type: .allow)
            let fetchedBlock = try await block
            let fetchedAllow = try await allow
            blockLists = fetchedBlock
            allowLists = fetchedAllow
            load.succeed()
        } catch {
            load.fail(error)
        }
    }

    @MainActor
    private func toggle(_ list: Adlist) async {
        guard let client = app.client else {
            return
        }
        do {
            try await client.updateList(
                address: list.address,
                type: list.listType,
                comment: list.comment,
                groups: list.groups,
                enabled: !list.enabled
            )
            await reload()
        } catch {
            load.fail(error)
        }
    }

    @MainActor
    private func delete(_ list: Adlist) async {
        guard let client = app.client else {
            return
        }
        do {
            try await client.deleteList(address: list.address, type: list.listType)
            await reload()
        } catch {
            load.fail(error)
        }
    }
}

private struct AdlistRow: View {
    @Environment(\.theme) private var theme
    let list: Adlist

    var body: some View {
        let statusTone = ListStatus.tone(list.status)

        HStack(alignment: .top, spacing: 10) {
            EnabledDot(enabled: list.enabled)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(list.address)
                    .font(.footnote.monospaced())
                    .foregroundStyle(list.enabled ? theme.text : theme.subtle)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if !list.comment.isEmpty {
                    Text(list.comment)
                        .font(.caption)
                        .foregroundStyle(theme.subtle)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Badge(
                        text: ListStatus.label(list.status),
                        color: statusTone == .neutral ? theme.subtle : theme.color(for: statusTone)
                    )
                    Text("\(Format.count(list.number)) domains")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(theme.subtle)
                    if list.invalidDomains > 0 {
                        Text("\(Format.count(list.invalidDomains)) invalid")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(theme.warn)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Add or edit an adlist. The address and type identify a list in FTL, so
/// they are fixed once it exists.
private struct AdlistForm: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let item: AdlistEditorItem
    let onSaved: () async -> Void

    @State private var address = ""
    @State private var type = ListType.block
    @State private var comment = ""
    @State private var groups: Set<Int> = [0]
    @State private var enabled = true
    @State private var prepared = false
    @State private var error: String?
    @State private var isSaving = false

    private var isEditing: Bool { item.original != nil }

    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        FormSheet(
            title: isEditing ? "Edit list" : "Add list",
            canSave: !trimmedAddress.isEmpty,
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
                    Text("Block").tag(ListType.block)
                    Text("Allow").tag(ListType.allow)
                }
                .pickerStyle(.segmented)
                .disabled(isEditing)
            }
            .rowStyle()

            Section {
                TextField("https://example.com/hosts.txt", text: $address, axis: .vertical)
                    .font(.footnote.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
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
            guard !prepared else {
                return
            }
            prepared = true
            type = item.type
            if let original = item.original {
                address = original.address
                comment = original.comment
                groups = Set(original.groups)
                enabled = original.enabled
            }
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
            let commentText = comment.trimmingCharacters(in: .whitespacesAndNewlines)
            if let original = item.original {
                try await client.updateList(
                    address: original.address,
                    type: original.listType,
                    comment: commentText,
                    groups: groups.sorted(),
                    enabled: enabled
                )
            } else {
                // A new list with no group would never apply to anyone.
                let chosen = groups.isEmpty ? [0] : groups.sorted()
                try await client.addList(
                    address: trimmedAddress,
                    type: type,
                    comment: commentText,
                    groups: chosen
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

/// Runs a gravity update and shows its output as it streams in.
private struct GravitySheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case running
        case done
        case failed(String)
    }

    @State private var lines: [String] = []
    @State private var phase = Phase.running

    private let bottomID = "gravity-bottom"

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                summary
                    .padding(12)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(theme.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(bottomID)
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    }
                    .onChange(of: lines.count) { _, _ in
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                }
            }
            .background(theme.surface.ignoresSafeArea())
            .navigationTitle("Gravity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(phase == .running ? "Cancel" : "Done") {
                        dismiss()
                    }
                }
            }
            .toolbarBackground(theme.panel, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .interactiveDismissDisabled(phase == .running)
        .task {
            await run()
        }
    }

    @ViewBuilder
    private var summary: some View {
        switch phase {
        case .running:
            HStack(spacing: 10) {
                ProgressView()
                Text("Running gravity update…")
                    .foregroundStyle(theme.subtle)
            }
        case .done:
            Label("Gravity update complete", systemImage: "checkmark.circle.fill")
                .foregroundStyle(theme.allow)
        case .failed(let message):
            ErrorBanner(message: "Gravity failed: \(message)")
        }
    }

    @MainActor
    private func run() async {
        guard let client = app.client else {
            phase = .failed(app.connectionProblem ?? "No active instance")
            return
        }
        do {
            for try await line in client.updateGravity() {
                lines.append(line)
            }
            phase = .done
        } catch {
            if ErrorText.isCancellation(error) {
                return
            }
            phase = .failed(ErrorText.describe(error))
        }
    }
}

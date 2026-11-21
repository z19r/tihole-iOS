import PiholeKit
import SwiftUI
import TiholeCore

/// What the group sheet is editing: an existing group, or a new one.
struct GroupEditorItem: Identifiable {
    let id = UUID()
    let original: PiholeGroup?
}

/// Groups scope domains, clients, and lists to subsets of the network.
struct GroupsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    @State private var groups: [PiholeGroup] = []
    @State private var load = LoadState()
    @State private var editor: GroupEditorItem?
    @State private var deleting: PiholeGroup?

    var body: some View {
        List {
            BannerSection(error: load.error ?? app.connectionProblem)

            Section {
                if groups.isEmpty {
                    ListPlaceholder(
                        load: load, loadingText: "Loading groups…",
                        emptyText: "No groups")
                } else {
                    ForEach(groups) { group in
                        Button {
                            editor = GroupEditorItem(original: group)
                        } label: {
                            GroupRow(group: group)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                deleting = group
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(theme.block)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                Task {
                                    await toggle(group)
                                }
                            } label: {
                                Label(
                                    group.enabled ? "Disable" : "Enable",
                                    systemImage: group.enabled
                                        ? "pause.circle" : "play.circle"
                                )
                            }
                            .tint(theme.accent)
                        }
                    }
                }
            }
            .rowStyle()
        }
        .screenStyle()
        .navigationTitle("Groups")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editor = GroupEditorItem(original: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add group")
            }
        }
        .refreshable {
            await reload()
        }
        .task(id: app.generation) {
            groups = []
            load = LoadState()
            await reload()
        }
        .sheet(item: $editor) { item in
            GroupForm(item: item) {
                await reload()
            }
        }
        .confirmationDialog(
            "Delete group?",
            isPresented: $deleting.isPresent(),
            titleVisibility: .visible,
            presenting: deleting
        ) { group in
            Button("Delete", role: .destructive) {
                Task {
                    await delete(group)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { group in
            Text(group.name)
        }
    }

    @MainActor
    private func reload() async {
        guard let client = app.client else {
            return
        }
        load.begin()
        do {
            groups = try await client.groups()
            load.succeed()
        } catch {
            load.fail(error)
        }
    }

    @MainActor
    private func toggle(_ group: PiholeGroup) async {
        guard let client = app.client else {
            return
        }
        do {
            try await client.updateGroup(
                name: group.name, comment: group.comment,
                enabled: !group.enabled)
            await reload()
        } catch {
            load.fail(error)
        }
    }

    @MainActor
    private func delete(_ group: PiholeGroup) async {
        guard let client = app.client else {
            return
        }
        do {
            try await client.deleteGroup(name: group.name)
            await reload()
        } catch {
            load.fail(error)
        }
    }
}

private struct GroupRow: View {
    @Environment(\.theme) private var theme
    let group: PiholeGroup

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            EnabledDot(enabled: group.enabled)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(group.enabled ? theme.text : theme.subtle)
                if !group.comment.isEmpty {
                    Text(group.comment)
                        .font(.caption)
                        .foregroundStyle(theme.subtle)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text("id \(group.id)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(theme.subtle)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Add or edit a group. The name identifies a group in FTL, so it is fixed
/// once the group exists.
private struct GroupForm: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let item: GroupEditorItem
    let onSaved: () async -> Void

    @State private var name = ""
    @State private var comment = ""
    @State private var enabled = true
    @State private var prepared = false
    @State private var error: String?
    @State private var isSaving = false

    private var isEditing: Bool { item.original != nil }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        FormSheet(
            title: isEditing ? "Edit group" : "Add group",
            canSave: !trimmedName.isEmpty,
            isSaving: isSaving,
            error: error,
            onSave: {
                Task {
                    await save()
                }
            }
        ) {
            Section {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(isEditing)
                TextField("Comment (optional)", text: $comment)
                if isEditing {
                    Toggle("Enabled", isOn: $enabled)
                }
            }
            .rowStyle()
        }
        .onAppear {
            guard !prepared else {
                return
            }
            prepared = true
            if let original = item.original {
                name = original.name
                comment = original.comment
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
            let commentText = comment.trimmingCharacters(
                in: .whitespacesAndNewlines)
            if let original = item.original {
                try await client.updateGroup(
                    name: original.name, comment: commentText, enabled: enabled)
            } else {
                try await client.addGroup(
                    name: trimmedName, comment: commentText)
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

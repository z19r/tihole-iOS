import PiholeKit
import SwiftUI
import TiholeCore

/// One top-level config section ("dns", "webserver") and its settings.
private struct ConfigSection: Identifiable {
    let name: String
    var leaves: [ConfigLeaf]
    var id: String { name }
}

/// Browse and edit the entire FTL configuration tree.
struct ConfigTreeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    @State private var leaves: [ConfigLeaf] = []
    @State private var load = LoadState()
    @State private var query = ""
    @State private var editing: ConfigLeaf?

    /// The filtered leaves grouped by their first path segment. `leaves` is
    /// path-sorted, so sections and their contents come out in order.
    private var sections: [ConfigSection] {
        var out: [ConfigSection] = []
        for leaf in ConfigTree.filter(leaves, query: query) {
            if let last = out.indices.last, out[last].name == leaf.section {
                out[last].leaves.append(leaf)
            } else {
                out.append(ConfigSection(name: leaf.section, leaves: [leaf]))
            }
        }
        return out
    }

    var body: some View {
        let grouped = sections

        List {
            BannerSection(error: load.error ?? app.connectionProblem)

            if grouped.isEmpty {
                Section {
                    ListPlaceholder(
                        load: load,
                        loadingText: "Loading configuration…",
                        emptyText: query.isEmpty ? "No settings" : "No settings match \"\(query)\""
                    )
                }
                .rowStyle()
            } else {
                ForEach(grouped) { section in
                    Section {
                        ForEach(section.leaves) { leaf in
                            Button {
                                editing = leaf
                            } label: {
                                ConfigLeafRow(leaf: leaf)
                            }
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
        .navigationTitle("Configuration")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Filter settings")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .refreshable {
            await reload()
        }
        .task(id: app.generation) {
            leaves = []
            load = LoadState()
            await reload()
        }
        .sheet(item: $editing) { leaf in
            ConfigLeafSheet(leaf: leaf) {
                await reload()
            }
        }
    }

    @MainActor
    private func reload() async {
        guard let client = app.client else {
            return
        }
        load.begin()
        do {
            let tree = try await client.config(detailed: true)
            leaves = ConfigTree.flatten(tree)
            load.succeed()
        } catch {
            load.fail(error)
        }
    }
}

/// The color a config value is shown in: booleans green/red, numbers accent.
private func valueColor(_ value: JSONValue, theme: Theme) -> Color {
    switch value {
    case .bool(let flag):
        return flag ? theme.allow : theme.block
    case .number:
        return theme.accent
    case .null, .string, .array, .object:
        return theme.text
    }
}

private struct ConfigLeafRow: View {
    @Environment(\.theme) private var theme
    let leaf: ConfigLeaf

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(leaf.name)
                    .font(.footnote.monospaced())
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if leaf.modified {
                    Circle()
                        .fill(theme.warn)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("Modified")
                }
            }
            Text(ConfigTree.stringify(leaf.value))
                .font(.caption.monospaced())
                .foregroundStyle(valueColor(leaf.value, theme: theme))
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One setting in full: what it is, its type and default, and an editor that
/// fits its type.
private struct ConfigLeafSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let leaf: ConfigLeaf
    let onSaved: () async -> Void

    @State private var flag = false
    @State private var text = ""
    @State private var items: [String] = []
    @State private var newItem = ""
    @State private var prepared = false
    @State private var error: String?
    @State private var isSaving = false

    private var kind: ConfigEditKind {
        ConfigTree.editKind(leaf)
    }

    var body: some View {
        FormSheet(
            title: leaf.name,
            canSave: kind != .readOnly,
            isSaving: isSaving,
            error: error,
            onSave: {
                Task {
                    await save()
                }
            }
        ) {
            Section {
                Text(leaf.path)
                    .font(.footnote.monospaced())
                    .foregroundStyle(theme.accent)
                    .textSelection(.enabled)
                if !leaf.description.isEmpty {
                    Text(leaf.description)
                        .font(.footnote)
                        .foregroundStyle(theme.text)
                }
            }
            .rowStyle()

            Section {
                editor
            } header: {
                Text("Value")
            }
            .rowStyle()

            Section {
                DetailRow(label: "Type", value: ConfigTree.typeLabel(leaf))
                DetailRow(
                    label: "Default",
                    value: ConfigTree.stringify(leaf.defaultValue),
                    valueColor: theme.subtle,
                    monospaced: true
                )
                DetailRow(
                    label: "Current",
                    value: ConfigTree.stringify(leaf.value),
                    valueColor: valueColor(leaf.value, theme: theme),
                    monospaced: true
                )
                DetailRow(
                    label: "Status",
                    value: leaf.modified ? "modified" : "unchanged from default",
                    valueColor: leaf.modified ? theme.warn : theme.subtle
                )
            } header: {
                Text("Details")
            }
            .rowStyle()
        }
        .onAppear {
            prepare()
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch kind {
        case .toggle:
            Toggle(flag ? "true" : "false", isOn: $flag)
        case .number:
            TextField("Number", text: $text)
                .font(.body.monospaced())
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
        case .text:
            TextField("Value", text: $text, axis: .vertical)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .choice(let options):
            Picker("Value", selection: $text) {
                ForEach(choices(options), id: \.self) { option in
                    Text(option).tag(option)
                }
            }
        case .stringList:
            listEditor
        case .readOnly:
            Text(ConfigTree.stringify(leaf.value))
                .font(.footnote.monospaced())
                .foregroundStyle(theme.subtle)
            Text("This setting has a structure that can't be edited here.")
                .font(.footnote)
                .foregroundStyle(theme.subtle)
        }
    }

    @ViewBuilder
    private var listEditor: some View {
        if items.isEmpty {
            Text("Empty list")
                .foregroundStyle(theme.subtle)
        }
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
            HStack {
                Text(item)
                    .font(.footnote.monospaced())
                    .foregroundStyle(theme.text)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button {
                    if items.indices.contains(index) {
                        items.remove(at: index)
                    }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(theme.block)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(item)")
            }
        }
        HStack {
            TextField("New entry", text: $newItem)
                .font(.footnote.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit {
                    addItem()
                }
            Button {
                addItem()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.borderless)
            .disabled(newItem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Add entry")
        }
    }

    /// The allowed options, plus the current value if FTL holds one that is
    /// not in its own list, so the picker always has a matching tag.
    private func choices(_ options: [String]) -> [String] {
        options.contains(text) ? options : [text] + options
    }

    private func addItem() {
        let trimmed = newItem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        items.append(trimmed)
        newItem = ""
    }

    private func prepare() {
        guard !prepared else {
            return
        }
        prepared = true
        switch leaf.value {
        case .bool(let value):
            flag = value
        case .array(let values):
            items = values.compactMap { $0.stringValue }
        case .null, .number, .string, .object:
            text = ConfigTree.stringify(leaf.value)
        }
    }

    /// The edited value as JSON of the same type as the original.
    private func editedValue() throws -> JSONValue {
        switch kind {
        case .toggle:
            return .bool(flag)
        case .number, .text:
            return try ConfigTree.parse(original: leaf.value, input: text)
        case .choice:
            return .string(text)
        case .stringList:
            // An entry typed but not yet added still counts.
            var all = items
            let pendingItem = newItem.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pendingItem.isEmpty {
                all.append(pendingItem)
            }
            return .array(all.map { JSONValue.string($0) })
        case .readOnly:
            return leaf.value
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
            let value = try editedValue()
            try await client.patchConfig(ConfigTree.patch(path: leaf.path, value: value), restart: false)
            await onSaved()
            dismiss()
        } catch {
            if !ErrorText.isCancellation(error) {
                self.error = ErrorText.describe(error)
            }
        }
    }
}

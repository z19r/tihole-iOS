import PiholeKit
import SwiftUI
import TiholeCore

/// Loading and error state shared by every screen that fetches something.
struct LoadState: Equatable {
    var isLoading = false
    /// True once any fetch has succeeded, so screens can tell "still loading"
    /// from "loaded and empty".
    var hasLoaded = false
    var error: String?

    mutating func begin() {
        isLoading = true
    }

    mutating func succeed() {
        isLoading = false
        hasLoaded = true
        error = nil
    }

    /// Records a failure. Cancellations are not errors and are dropped.
    mutating func fail(_ error: Error, destructive: Bool = false) {
        isLoading = false
        if ErrorText.isCancellation(error) {
            return
        }
        self.error =
            destructive
            ? ErrorText.describeDestructive(error)
            : ErrorText.describe(error)
    }

    mutating func fail(message: String) {
        isLoading = false
        error = message
    }
}

/// Calls `body` immediately and then every `seconds` until the surrounding
/// task is cancelled. Screens run this from `.task`, which SwiftUI cancels
/// when the view disappears, so polling stops as soon as a screen is left.
@MainActor
func repeatEvery(_ seconds: Double, _ body: @MainActor () async -> Void) async {
    while !Task.isCancelled {
        await body()
        try? await Task.sleep(for: .seconds(seconds))
    }
}

// MARK: - Containers

/// A raised, bordered panel with an optional title.
struct Card<Content: View>: View {
    @Environment(\.theme) private var theme

    private let title: String?
    private let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.text)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            theme.panel,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
    }
}

/// An inline, non-fatal error.
struct ErrorBanner: View {
    @Environment(\.theme) private var theme
    let message: String

    var body: some View {
        Label {
            Text(message)
                .font(.footnote)
                .foregroundStyle(theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.block)
        }
        .padding(10)
        .background(
            theme.block.opacity(0.14),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.block.opacity(0.5), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

/// A transient success note.
struct NoteBanner: View {
    @Environment(\.theme) private var theme
    let message: String

    var body: some View {
        Label {
            Text(message)
                .font(.footnote)
                .foregroundStyle(theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(theme.allow)
        }
        .padding(10)
        .background(
            theme.allow.opacity(0.14),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A small capsule label.
struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
    }
}

/// Filled when enabled, hollow when disabled.
struct EnabledDot: View {
    @Environment(\.theme) private var theme
    let enabled: Bool

    var body: some View {
        Image(systemName: enabled ? "circle.fill" : "circle")
            .font(.caption2)
            .foregroundStyle(enabled ? theme.allow : theme.subtle)
            .accessibilityLabel(enabled ? "Enabled" : "Disabled")
    }
}

/// A label/value line for detail views.
struct DetailRow: View {
    @Environment(\.theme) private var theme
    let label: String
    let value: String
    var valueColor: Color?
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(theme.subtle)
            Spacer(minLength: 8)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .foregroundStyle(valueColor ?? theme.text)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

/// A horizontal proportion bar: label, filled track, count.
struct BreakdownRow: View {
    @Environment(\.theme) private var theme
    let label: String
    let count: Int
    let fraction: Double
    var color: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(Format.count(count))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(theme.subtle)
            }
            ProgressView(value: min(max(fraction, 0), 1))
                .tint(color ?? theme.accent)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Screen styling

private struct ScreenStyle: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(theme.surface.ignoresSafeArea())
            .toolbarBackground(theme.panel, for: .navigationBar, .tabBar)
            .toolbarBackground(.visible, for: .navigationBar, .tabBar)
    }
}

private struct RowStyle: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .listRowBackground(theme.panel)
            .listRowSeparatorTint(theme.border)
            .foregroundStyle(theme.text)
    }
}

extension View {
    /// Paints a list, form, or scroll view with the theme's surface and gives
    /// its navigation bar the panel color.
    func screenStyle() -> some View {
        modifier(ScreenStyle())
    }

    /// Paints a list row with the theme's panel color.
    func rowStyle() -> some View {
        modifier(RowStyle())
    }
}

/// A list section holding an error and/or note banner, shown only when there
/// is something to say.
struct BannerSection: View {
    var error: String?
    var note: String?

    var body: some View {
        if error != nil || note != nil {
            Section {
                if let error {
                    ErrorBanner(message: error)
                }
                if let note {
                    NoteBanner(message: note)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(
                EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
            )
            .listRowSeparator(.hidden)
        }
    }
}

// MARK: - Group picker

/// Form section for choosing which groups an entry belongs to. It loads the
/// instance's groups itself; if that fails it falls back to typing ids.
struct GroupPickerSection: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    @Binding var selection: Set<Int>

    @State private var groups: [PiholeGroup] = []
    @State private var loadFailed = false
    @State private var typedIDs = ""

    var body: some View {
        Section {
            if !groups.isEmpty {
                ForEach(groups) { group in
                    Button {
                        toggle(group.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.name)
                                    .foregroundStyle(theme.text)
                                if !group.comment.isEmpty {
                                    Text(group.comment)
                                        .font(.caption)
                                        .foregroundStyle(theme.subtle)
                                }
                            }
                            Spacer()
                            if selection.contains(group.id) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(theme.accent)
                            }
                        }
                    }
                    .accessibilityAddTraits(
                        selection.contains(group.id) ? .isSelected : [])
                }
            } else if loadFailed {
                TextField("Group ids, e.g. 0, 2", text: $typedIDs)
                    .keyboardType(.numbersAndPunctuation)
                    .onChange(of: typedIDs) { _, value in
                        selection = Set(GroupIDs.parse(value))
                    }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading groups…")
                        .foregroundStyle(theme.subtle)
                }
                .task {
                    await load()
                }
            }
        } header: {
            Text("Groups")
        }
        .rowStyle()
    }

    private func toggle(_ id: Int) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    @MainActor
    private func load() async {
        guard let client = app.client else {
            typedIDs = GroupIDs.csv(selection.sorted())
            loadFailed = true
            return
        }
        do {
            let fetched = try await client.groups()
            if fetched.isEmpty {
                typedIDs = GroupIDs.csv(selection.sorted())
                loadFailed = true
            } else {
                groups = fetched
            }
        } catch {
            if ErrorText.isCancellation(error) {
                return
            }
            typedIDs = GroupIDs.csv(selection.sorted())
            loadFailed = true
        }
    }
}

// MARK: - Presentation helpers

extension Binding {
    /// A Boolean binding that is true while this optional binding holds a
    /// value. Setting it to false clears the value. Lets an optional item
    /// drive an alert or confirmation dialog.
    func isPresent<Wrapped>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(
            get: { self.wrappedValue != nil },
            set: { isPresented in
                if !isPresented {
                    self.wrappedValue = nil
                }
            }
        )
    }
}

/// The frame every add/edit sheet shares: a form with an error banner, Cancel,
/// and Save.
struct FormSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss

    private let title: String
    private let canSave: Bool
    private let isSaving: Bool
    private let error: String?
    private let onSave: () -> Void
    private let content: Content

    init(
        title: String,
        canSave: Bool,
        isSaving: Bool,
        error: String?,
        onSave: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.canSave = canSave
        self.isSaving = isSaving
        self.error = error
        self.onSave = onSave
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            Form {
                BannerSection(error: error)
                content
            }
            .screenStyle()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            onSave()
                        }
                        .disabled(!canSave)
                    }
                }
            }
        }
    }
}

/// The placeholder row a list shows before its first load, or when it is
/// empty.
struct ListPlaceholder: View {
    @Environment(\.theme) private var theme
    let load: LoadState
    let loadingText: String
    let emptyText: String

    var body: some View {
        if load.isLoading && !load.hasLoaded {
            HStack(spacing: 10) {
                ProgressView()
                Text(loadingText)
                    .foregroundStyle(theme.subtle)
            }
        } else {
            Text(emptyText)
                .foregroundStyle(theme.subtle)
        }
    }
}

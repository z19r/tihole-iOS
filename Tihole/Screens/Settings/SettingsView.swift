import SwiftUI
import TiholeCore

/// What the instance sheet is editing: an existing instance, or a new one.
struct InstanceEditorItem: Identifiable {
    let id = UUID()
    let existing: InstanceConfig?
}

/// The Settings tab: connections, theme, and the Pi-hole's own configuration.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    @State private var editor: InstanceEditorItem?
    @State private var deleting: InstanceConfig?
    @State private var versionTaps = 0
    /// Set when the second Pi-hole is added; asked once the sheet closes.
    @State private var offerCombine = false
    @State private var showingCombinePrompt = false

    private var appVersion: String {
        let version =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "dev"
        let build =
            Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    var body: some View {
        List {
            BannerSection(error: app.connectionProblem)

            Section {
                ForEach(app.config.instances) { instance in
                    Button {
                        app.activate(instance.id)
                    } label: {
                        InstanceRow(
                            instance: instance,
                            isActive: instance.id == app.activeInstance?.id
                        )
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            deleting = instance
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(theme.block)

                        Button {
                            editor = InstanceEditorItem(existing: instance)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(theme.accent)
                    }
                }
                Button {
                    editor = InstanceEditorItem(existing: nil)
                } label: {
                    Label("Add instance", systemImage: "plus")
                }
            } header: {
                Text("Connections")
            } footer: {
                Text(
                    """
                    Tap an instance to make it active. Swipe left to edit or \
                    delete it.
                    """
                )
                .foregroundStyle(theme.subtle)
            }
            .rowStyle()

            Section {
                NavigationLink {
                    ThemePickerView()
                } label: {
                    LabeledContent("Theme", value: app.themeName.title)
                }
            } header: {
                Text("Appearance")
            }
            .rowStyle()

            Section {
                NavigationLink {
                    ConfigTreeView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Configuration")
                                .foregroundStyle(theme.text)
                            Text("Browse and edit every FTL setting")
                                .font(.caption)
                                .foregroundStyle(theme.subtle)
                        }
                    } icon: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(theme.accent)
                    }
                }
            } header: {
                Text("Pi-hole")
            }
            .rowStyle()

            Section {
                Button {
                    versionTaps += 1
                    if versionTaps >= 7 {
                        versionTaps = 0
                        app.toggleParty()
                    }
                } label: {
                    LabeledContent("Version", value: appVersion)
                        .foregroundStyle(theme.text)
                }
                if let url = URL(string: "https://github.com/z19r/tihole") {
                    Link(destination: url) {
                        Label(
                            "tihole on GitHub",
                            systemImage: "arrow.up.right.square")
                    }
                }
            } header: {
                Text("About")
            }
            .rowStyle()
        }
        .screenStyle()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .chrome()
        .onChange(of: app.config.instances.count) { old, new in
            offerCombine = old == 1 && new == 2 && !app.config.combined
        }
        .sheet(
            item: $editor,
            onDismiss: {
                // An alert presented while the sheet is closing is dropped.
                showingCombinePrompt = offerCombine
                offerCombine = false
            }
        ) { item in
            NavigationStack {
                InstanceForm(existing: item.existing) {
                    editor = nil
                }
                .navigationTitle(
                    item.existing == nil ? "Add instance" : "Edit instance"
                )
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            editor = nil
                        }
                    }
                }
            }
        }
        .alert("Combine dashboards?", isPresented: $showingCombinePrompt) {
            Button("Combine") {
                app.setCombined(true)
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text(
                """
                Show stats from both Pi-holes together by default? You can \
                switch anytime from the instance menu.
                """
            )
        }
        .confirmationDialog(
            "Delete instance?",
            isPresented: $deleting.isPresent(),
            titleVisibility: .visible,
            presenting: deleting
        ) { instance in
            Button("Delete", role: .destructive) {
                app.deleteInstance(instance.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { instance in
            Text(
                """
                \(instance.name) and its saved password will be removed from \
                this device.
                """
            )
        }
    }
}

private struct InstanceRow: View {
    @Environment(\.theme) private var theme
    let instance: InstanceConfig
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? theme.accent : theme.subtle)
            VStack(alignment: .leading, spacing: 2) {
                Text(instance.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(theme.text)
                Text(instance.url)
                    .font(.caption.monospaced())
                    .foregroundStyle(theme.subtle)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if !instance.verifyTLS {
                Badge(text: "TLS unverified", color: theme.warn)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Pick a theme. Each row previews the palette it would apply.
struct ThemePickerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        List {
            Section {
                ForEach(ThemeName.allCases) { name in
                    Button {
                        app.setTheme(name)
                    } label: {
                        row(name)
                    }
                }
            }
            .rowStyle()
        }
        .screenStyle()
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ name: ThemeName) -> some View {
        let preview = name.resolve(colorScheme: colorScheme)
        let isSelected = app.themeName == name

        return HStack(spacing: 12) {
            HStack(spacing: 0) {
                ForEach(
                    Array(
                        [
                            preview.accent, preview.allow, preview.warn,
                            preview.block,
                        ].enumerated()), id: \.offset
                ) { _, color in
                    color.frame(width: 12, height: 28)
                }
            }
            .background(preview.surface)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(name.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(theme.text)
                Text(name.blurb)
                    .font(.caption)
                    .foregroundStyle(theme.subtle)
            }
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(theme.accent)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

import SwiftUI
import TiholeCore

/// The persistent chrome every top-level screen carries in its navigation
/// bar: the instance switcher on the left and the blocking pill on the right.
/// It is the phone-sized version of the TUI's status bar.
private struct Chrome: ViewModifier {
    @Environment(AppModel.self) private var app

    @State private var showingBlocking = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    InstanceMenu()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingBlocking = true
                    } label: {
                        BlockingPill(state: app.blocking)
                    }
                    .accessibilityLabel(blockingAccessibilityLabel)
                    .accessibilityHint("Opens blocking controls")
                    .accessibilityIdentifier("blocking.pill")
                }
            }
            .sheet(isPresented: $showingBlocking) {
                BlockingSheet()
            }
    }

    private var blockingAccessibilityLabel: String {
        if !app.blocking.known {
            return "Blocking status unknown"
        }
        return app.blocking.enabled ? "Blocking is on" : "Blocking is off"
    }
}

extension View {
    /// Adds the instance switcher and blocking pill to the navigation bar.
    func chrome() -> some View {
        modifier(Chrome())
    }
}

/// Switches the active instance. Every screen reloads against the new one.
struct InstanceMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        Menu {
            ForEach(app.config.instances) { instance in
                Button {
                    app.activate(instance.id)
                } label: {
                    if instance.id == app.activeInstance?.id {
                        Label(instance.name, systemImage: "checkmark")
                    } else {
                        Text(instance.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "hexagon.fill")
                Text(app.activeInstance?.name ?? "tihole")
                    .lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(theme.accent)
        }
        .accessibilityLabel("Instance \(app.activeInstance?.name ?? "none")")
        .accessibilityHint("Switches the active Pi-hole")
    }
}

/// Blocking state at a glance: green when on, red when off, with a live
/// countdown while a temporary disable is running.
struct BlockingPill: View {
    @Environment(\.theme) private var theme
    let state: BlockingState

    var body: some View {
        if !state.known {
            pill("Blocking", icon: "circle.dotted", foreground: theme.subtle, background: theme.border)
        } else if state.enabled {
            pill("On", icon: "shield.fill", foreground: theme.surface, background: theme.allow)
        } else if state.resumesAt != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                pill(
                    "Off " + Format.countdown(seconds: state.remainingSeconds(at: context.date)),
                    icon: "exclamationmark.triangle.fill",
                    foreground: theme.surface,
                    background: theme.block
                )
            }
        } else {
            pill("Off", icon: "exclamationmark.triangle.fill", foreground: theme.surface, background: theme.block)
        }
    }

    private func pill(_ label: String, icon: String, foreground: Color, background: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(label)
                .monospacedDigit()
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(foreground)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(background, in: Capsule())
    }
}

/// The Blocking screen: current status plus the five actions the TUI offers.
struct BlockingSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var load = LoadState()

    private struct Choice: Identifiable {
        let id: Int
        let label: String
        let icon: String
        let enable: Bool
        let seconds: Double?
    }

    private let choices = [
        Choice(id: 0, label: "Enable blocking", icon: "shield.fill", enable: true, seconds: nil),
        Choice(id: 1, label: "Disable for 5 minutes", icon: "timer", enable: false, seconds: 300),
        Choice(id: 2, label: "Disable for 10 minutes", icon: "timer", enable: false, seconds: 600),
        Choice(id: 3, label: "Disable for 15 minutes", icon: "timer", enable: false, seconds: 900),
        Choice(id: 4, label: "Disable indefinitely", icon: "shield.slash", enable: false, seconds: nil),
    ]

    var body: some View {
        NavigationStack {
            List {
                BannerSection(error: load.error ?? app.connectionProblem)

                Section {
                    statusRow
                }
                .rowStyle()

                Section {
                    ForEach(choices) { choice in
                        Button {
                            Task {
                                await apply(choice)
                            }
                        } label: {
                            Label(choice.label, systemImage: choice.icon)
                                .foregroundStyle(choice.enable ? theme.allow : theme.text)
                        }
                        .disabled(load.isLoading)
                    }
                }
                .rowStyle()
            }
            .screenStyle()
            .navigationTitle("Blocking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await app.refreshBlocking()
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var statusRow: some View {
        let state = app.blocking
        if !state.known {
            Label("Checking status…", systemImage: "circle.dotted")
                .foregroundStyle(theme.subtle)
        } else if state.enabled {
            Label("Blocking is on", systemImage: "shield.fill")
                .font(.headline)
                .foregroundStyle(theme.allow)
        } else if state.resumesAt != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Label(
                    "Blocking is off. Re-enables in "
                        + Format.countdown(seconds: state.remainingSeconds(at: context.date)),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.headline)
                .foregroundStyle(theme.block)
                .monospacedDigit()
            }
        } else {
            Label("Blocking is off", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(theme.block)
        }
    }

    @MainActor
    private func apply(_ choice: Choice) async {
        load.begin()
        do {
            try await app.setBlocking(enabled: choice.enable, seconds: choice.seconds)
            load.succeed()
            dismiss()
        } catch {
            load.fail(error)
        }
    }
}

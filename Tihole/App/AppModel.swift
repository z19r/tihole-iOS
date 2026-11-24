import Foundation
import Observation
import PiholeKit
import SwiftUI
import TiholeCore
import UIKit

/// What the blocking pill shows.
struct BlockingState: Equatable {
    /// False until the first status fetch succeeds.
    var known = false
    var enabled = false
    /// When a temporary disable ends, if one is running.
    var resumesAt: Date?
    /// In combined mode, the Pi-holes blocking out of every configured one,
    /// unreachable ones included. `total` is 0 for a single instance.
    var on = 0
    var total = 0

    /// Some reachable combined members block and some do not.
    var isPartial: Bool {
        total > 0 && !enabled && on > 0
    }

    /// Every reachable member blocks, but some Pi-holes did not answer.
    var hasUnreachable: Bool {
        total > 0 && enabled && on < total
    }

    /// Seconds until blocking turns back on, or 0 when there is no timer.
    func remainingSeconds(at now: Date = Date()) -> Int {
        guard let resumesAt else {
            return 0
        }
        return max(0, Int(resumesAt.timeIntervalSince(now).rounded()))
    }
}

/// The editable fields of an instance, as typed into the form.
struct InstanceDraft: Equatable {
    var name = ""
    var url = ""
    var password = ""
    var verifyTLS = true
}

/// One or more reasons a config change was rejected.
struct ConfigProblem: LocalizedError {
    let messages: [String]

    var errorDescription: String? {
        messages.joined(separator: "\n")
    }
}

/// Mutable holder for a UIKit background-task id, shared between the task
/// body and its expiration handler.
private final class BackgroundTaskBox: @unchecked Sendable {
    var identifier = UIBackgroundTaskIdentifier.invalid
}

/// App-wide state: the saved config, the active instance's client, the theme,
/// and the blocking status every screen's toolbar shows.
///
/// This plays the role of the TUI's `AppContext`: screens read the client and
/// theme from here and never construct their own.
@MainActor
@Observable
final class AppModel {
    private(set) var config: AppConfig

    /// The active instance's client, or nil when there is no usable instance
    /// (see `connectionProblem`).
    private(set) var client: PiholeClient?

    /// Every instance read as one, or nil unless combined mode is on with two
    /// or more instances. Its member for the active instance is `client`, so
    /// the session is shared.
    private(set) var combinedClient: CombinedClient?

    /// Bumps whenever `client` is replaced. Screens key their loading tasks on
    /// it, so switching instances restarts every fetch.
    private(set) var generation = 0

    /// Why there is no client, when there should be one.
    private(set) var connectionProblem: String?

    private(set) var blocking = BlockingState()

    /// False while the app is in the background. Polling loops skip their
    /// fetches then, so they do not reopen the session that was just closed.
    private(set) var isForeground = true

    private(set) var partyMode = false
    private(set) var partyDate = Date()

    @ObservationIgnored private var partyTimer: Timer?

    init() {
        #if DEBUG
            // UI tests launch with this flag so every run starts at onboarding.
            if ProcessInfo.processInfo.arguments.contains("--reset-state") {
                ConfigStore.reset()
            }
        #endif
        config = ConfigStore.load()
        rebuildClient()
    }

    // MARK: - Theme

    var themeName: ThemeName {
        ThemeName(rawValue: config.theme) ?? .auto
    }

    func theme(for colorScheme: ColorScheme) -> Theme {
        if partyMode {
            return Theme.party(at: partyDate)
        }
        return themeName.resolve(colorScheme: colorScheme)
    }

    var preferredColorScheme: ColorScheme? {
        partyMode ? .dark : themeName.preferredColorScheme
    }

    func setTheme(_ name: ThemeName) {
        config.theme = name.rawValue
        ConfigStore.save(config)
    }

    /// Flips the rainbow easter egg. While on, the theme is re-resolved ten
    /// times a second so every color drifts through the hue wheel.
    func toggleParty() {
        partyMode.toggle()
        partyTimer?.invalidate()
        partyTimer = nil
        guard partyMode else {
            return
        }
        partyTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true)
        { [weak self] _ in
            Task { @MainActor in
                self?.partyDate = Date()
            }
        }
    }

    // MARK: - Instances

    /// True when the dashboard and query log should merge every instance.
    var isCombined: Bool {
        combinedClient != nil
    }

    /// Combined mode needs at least two instances to mean anything.
    var canCombine: Bool {
        config.instances.count > 1
    }

    /// True when the read views have something to read: the active client,
    /// or, in combined mode, any reachable Pi-hole.
    var canRead: Bool {
        client != nil || isCombined
    }

    /// The active client, or the reason there is none. Combined screens use
    /// it for the per-machine panels so those fail alone.
    func requireClient() throws -> PiholeClient {
        guard let client else {
            throw ConfigProblem(messages: [
                connectionProblem ?? "No active instance"
            ])
        }
        return client
    }

    /// Switches the read views between every instance and the active one,
    /// and remembers the choice.
    func setCombined(_ on: Bool) {
        guard config.combined != on else {
            return
        }
        config.combined = on
        ConfigStore.save(config)
        // The pill now speaks for a different set of Pi-holes.
        blocking = BlockingState()
        rebuildCombined()
        generation += 1
    }

    var activeInstance: InstanceConfig? {
        config.activeInstance
    }

    /// Replaces the client for the active instance and resets per-instance
    /// state. The previous client's session is closed in the background.
    private func rebuildClient() {
        let previous = client
        client = nil
        blocking = BlockingState()
        generation += 1

        if let previous {
            Task {
                try? await previous.logout()
            }
        }

        if let instance = config.activeInstance {
            switch Self.makeClient(for: instance) {
            case .success(let made):
                client = made
                connectionProblem = nil
            case .failure(let problem):
                connectionProblem = problem.messages.joined(separator: "\n")
            }
        } else {
            connectionProblem = nil
        }
        rebuildCombined()
    }

    /// Rebuilds `combinedClient` from every instance, reusing `client` for
    /// the active one. Instances that cannot be built count as unreachable.
    private func rebuildCombined() {
        let previous = combinedClient
        combinedClient = nil
        let active = client
        if let previous {
            Task {
                for member in previous.members where member.client !== active {
                    try? await member.client.logout()
                }
            }
        }
        // Off by default, so single mode never holds idle sessions (or starts
        // the demo server) for the other instances.
        guard config.combined, canCombine else {
            return
        }

        var members: [CombinedClient.Member] = []
        var unavailable: [String: String] = [:]
        for instance in config.instances {
            if instance.id == config.activeInstance?.id, let active {
                members.append(.init(name: instance.name, client: active))
            } else {
                switch Self.makeClient(for: instance) {
                case .success(let made):
                    members.append(.init(name: instance.name, client: made))
                case .failure(let problem):
                    unavailable[instance.name] =
                        problem.errorDescription ?? "not set up"
                }
            }
        }
        // Kept even with no buildable member, so the screens say which
        // Pi-holes are unreachable instead of quietly going single.
        combinedClient = CombinedClient(
            members: members, unavailable: unavailable)
    }

    /// A client for `instance`, or why one cannot be made.
    private static func makeClient(for instance: InstanceConfig)
        -> Result<PiholeClient, ConfigProblem>
    {
        if let problem = InstanceConfig.urlProblem(instance.url) {
            return .failure(
                ConfigProblem(messages: ["\(instance.name): \(problem)"]))
        }
        if instance.url == MockPihole.demoURL {
            do {
                try MockPihole.startDemo()
            } catch {
                return .failure(
                    ConfigProblem(messages: [
                        """
                        The demo Pi-hole could not start: \
                        \(error.localizedDescription)
                        """
                    ]))
            }
        }
        guard let password = Keychain.password(for: instance.id),
            !password.isEmpty
        else {
            return .failure(
                ConfigProblem(messages: [
                    """
                    No password saved for \(instance.name). Edit the instance \
                    in Settings.
                    """
                ]))
        }
        return .success(
            PiholeClient(
                baseURL: instance.url,
                password: password,
                verifyTLS: instance.verifyTLS
            ))
    }

    /// Rebuilds the combined client after an edit that left the active
    /// instance alone, restarting the read views when they use it.
    private func instancesChanged() {
        let wasCombined = isCombined
        rebuildCombined()
        if wasCombined || isCombined {
            // The pill's counts may cover a different set of Pi-holes now.
            blocking = BlockingState()
            generation += 1
        }
    }

    /// Creates an instance (`id` nil) or updates an existing one. A blank
    /// password on an existing instance keeps the stored one.
    func saveInstance(id: UUID?, draft: InstanceDraft) throws {
        let (next, instanceID) = config.upserting(
            id: id,
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            url: InstanceConfig.normalizedURL(draft.url),
            verifyTLS: draft.verifyTLS
        )

        var problems = next.validationErrors()
        let hasStoredPassword = !(Keychain.password(for: instanceID) ?? "")
            .isEmpty
        if draft.password.isEmpty && !hasStoredPassword {
            problems.append("password is required")
        }
        guard problems.isEmpty else {
            throw ConfigProblem(messages: problems)
        }

        if !draft.password.isEmpty {
            try Keychain.setPassword(draft.password, for: instanceID)
        }
        config = next
        ConfigStore.save(next)

        if next.activeInstance?.id == instanceID {
            rebuildClient()
        } else {
            instancesChanged()
        }
    }

    /// Adds and activates an instance backed by the in-app demo server.
    func addDemo() throws {
        let draft = InstanceDraft(
            name: "Demo", url: MockPihole.demoURL, password: MockPihole.password
        )
        try saveInstance(id: nil, draft: draft)
    }

    func deleteInstance(_ id: UUID) {
        let wasActive = config.activeInstance?.id == id
        config = config.removing(id)
        Keychain.deletePassword(for: id)
        ConfigStore.save(config)
        if wasActive {
            rebuildClient()
        } else {
            instancesChanged()
        }
    }

    func activate(_ id: UUID) {
        guard config.activeInstance?.id != id,
            config.instances.contains(where: { $0.id == id })
        else {
            return
        }
        config.activeID = id
        ConfigStore.save(config)
        rebuildClient()
    }

    /// Logs in with the draft's settings without saving anything, so the
    /// form can report a bad address or password before committing.
    static func testConnection(draft: InstanceDraft, existingID: UUID?)
        async throws
    {
        let url = InstanceConfig.normalizedURL(draft.url)
        if let problem = InstanceConfig.urlProblem(url) {
            throw ConfigProblem(messages: [problem])
        }
        var password = draft.password
        if password.isEmpty, let existingID {
            password = Keychain.password(for: existingID) ?? ""
        }
        guard !password.isEmpty else {
            throw ConfigProblem(messages: ["password is required"])
        }
        let probe = PiholeClient(
            baseURL: url, password: password, verifyTLS: draft.verifyTLS)
        try await probe.login()
        try? await probe.logout()
    }

    // MARK: - Blocking

    /// Fetches the blocking status for the toolbar pill. Failures leave the
    /// last known state in place; the screens report connection errors.
    func refreshBlocking() async {
        guard isForeground else {
            return
        }
        let startedAt = generation
        guard let status = try? await fetchBlocking(), startedAt == generation
        else {
            return
        }
        applyBlocking(status)
    }

    /// Blocking from every Pi-hole in combined mode, else the active one.
    private func fetchBlocking() async throws -> BlockingStatus? {
        if let combinedClient {
            return try await combinedClient.blocking().value
        }
        return try await client?.blocking()
    }

    private func applyBlocking(_ status: BlockingStatus) {
        var next = BlockingState(
            known: true, enabled: status.isBlocking, on: status.on,
            total: status.total)
        if !status.isBlocking, let timer = status.timer, timer > 0 {
            next.resumesAt = Date().addingTimeInterval(timer)
        }
        // Assign only on change: every assignment redraws each toolbar.
        if next != blocking {
            blocking = next
        }
    }

    /// Turns blocking on, or off for `seconds` (nil means until re-enabled).
    /// In combined mode this changes every Pi-hole, since disabling one
    /// leaves the network blocked through the others.
    func setBlocking(enabled: Bool, seconds: Double?) async throws {
        let timer = enabled ? nil : seconds
        if let combinedClient {
            do {
                try await combinedClient.setBlocking(enabled, timer: timer)
            } catch {
                // Show the real per-member count, then the failure.
                await refreshBlocking()
                throw error
            }
            await refreshBlocking()
            return
        }
        guard let client else {
            throw ConfigProblem(messages: [
                connectionProblem ?? "No active instance"
            ])
        }
        try await client.setBlocking(enabled, timer: timer)
        applyBlocking(try await client.blocking())
    }

    // MARK: - Scene lifecycle

    /// Closes the FTL session when the app leaves the foreground so it does
    /// not hold one of the server's limited session seats. The next request
    /// after returning logs in again transparently.
    func sceneDidEnterBackground() {
        isForeground = false
        var clients = combinedClient?.members.map(\.client) ?? []
        if let client, !clients.contains(where: { $0 === client }) {
            clients.append(client)
        }
        guard !clients.isEmpty else {
            return
        }
        let application = UIApplication.shared
        let box = BackgroundTaskBox()
        box.identifier = application.beginBackgroundTask(
            withName: "tihole.logout"
        ) {
            application.endBackgroundTask(box.identifier)
            box.identifier = .invalid
        }
        Task {
            await withTaskGroup(of: Void.self) { group in
                for client in clients {
                    group.addTask {
                        try? await client.logout()
                    }
                }
            }
            application.endBackgroundTask(box.identifier)
            box.identifier = .invalid
        }
    }

    func sceneDidBecomeActive() {
        isForeground = true
        // iOS may close the demo server's socket while the app is suspended.
        if config.instances.contains(where: { $0.url == MockPihole.demoURL }) {
            try? MockPihole.startDemo()
        }
    }
}

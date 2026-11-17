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
        partyTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.partyDate = Date()
            }
        }
    }

    // MARK: - Instances

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

        guard let instance = config.activeInstance else {
            connectionProblem = nil
            return
        }
        if let problem = InstanceConfig.urlProblem(instance.url) {
            connectionProblem = "\(instance.name): \(problem)"
            return
        }
        guard let password = Keychain.password(for: instance.id), !password.isEmpty else {
            connectionProblem = "No password saved for \(instance.name). Edit the instance in Settings."
            return
        }
        client = PiholeClient(
            baseURL: instance.url,
            password: password,
            verifyTLS: instance.verifyTLS
        )
        connectionProblem = nil
    }

    /// Creates an instance (`id` nil) or updates an existing one. A blank
    /// password on an existing instance keeps the stored one.
    func saveInstance(id: UUID?, draft: InstanceDraft) throws {
        var next = config
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = InstanceConfig.normalizedURL(draft.url)

        let instanceID: UUID
        if let id, let index = next.instances.firstIndex(where: { $0.id == id }) {
            next.instances[index].name = name
            next.instances[index].url = url
            next.instances[index].verifyTLS = draft.verifyTLS
            instanceID = id
        } else {
            let instance = InstanceConfig(name: name, url: url, verifyTLS: draft.verifyTLS)
            next.instances.append(instance)
            instanceID = instance.id
        }

        let activeStillExists = next.instances.contains { $0.id == next.activeID }
        if !activeStillExists {
            next.activeID = instanceID
        }

        var problems = next.validationErrors()
        let hasStoredPassword = !(Keychain.password(for: instanceID) ?? "").isEmpty
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
        }
    }

    func deleteInstance(_ id: UUID) {
        let wasActive = config.activeInstance?.id == id
        config.instances.removeAll { $0.id == id }
        Keychain.deletePassword(for: id)
        if wasActive || !config.instances.contains(where: { $0.id == config.activeID }) {
            config.activeID = config.instances.first?.id
        }
        ConfigStore.save(config)
        if wasActive {
            rebuildClient()
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
    static func testConnection(draft: InstanceDraft, existingID: UUID?) async throws {
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
        let probe = PiholeClient(baseURL: url, password: password, verifyTLS: draft.verifyTLS)
        try await probe.login()
        try? await probe.logout()
    }

    // MARK: - Blocking

    /// Fetches the blocking status for the toolbar pill. Failures leave the
    /// last known state in place; the screens report connection errors.
    func refreshBlocking() async {
        guard let client, isForeground else {
            return
        }
        let startedAt = generation
        guard let status = try? await client.blocking(), startedAt == generation else {
            return
        }
        applyBlocking(status)
    }

    private func applyBlocking(_ status: BlockingStatus) {
        var next = BlockingState(known: true, enabled: status.isBlocking)
        if !status.isBlocking, let timer = status.timer, timer > 0 {
            next.resumesAt = Date().addingTimeInterval(timer)
        }
        blocking = next
    }

    /// Turns blocking on, or off for `seconds` (nil means until re-enabled).
    func setBlocking(enabled: Bool, seconds: Double?) async throws {
        guard let client else {
            throw ConfigProblem(messages: [connectionProblem ?? "No active instance"])
        }
        try await client.setBlocking(enabled, timer: enabled ? nil : seconds)
        applyBlocking(try await client.blocking())
    }

    // MARK: - Scene lifecycle

    /// Closes the FTL session when the app leaves the foreground so it does
    /// not hold one of the server's limited session seats. The next request
    /// after returning logs in again transparently.
    func sceneDidEnterBackground() {
        isForeground = false
        guard let client else {
            return
        }
        let application = UIApplication.shared
        let box = BackgroundTaskBox()
        box.identifier = application.beginBackgroundTask(withName: "tihole.logout") {
            application.endBackgroundTask(box.identifier)
            box.identifier = .invalid
        }
        Task {
            try? await client.logout()
            application.endBackgroundTask(box.identifier)
            box.identifier = .invalid
        }
    }

    func sceneDidBecomeActive() {
        isForeground = true
    }
}

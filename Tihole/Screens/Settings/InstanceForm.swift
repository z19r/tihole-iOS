import SwiftUI
import TiholeCore

/// Add or edit a Pi-hole instance. Used by onboarding and by Settings.
struct InstanceForm: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    /// The instance being edited, or nil when adding a new one.
    let existing: InstanceConfig?
    /// Called after a successful save.
    var onSaved: () -> Void = {}

    @State private var draft = InstanceDraft()
    @State private var loadedDraft = false
    @State private var problem: String?
    @State private var isTesting = false
    @State private var testPassed = false
    @State private var testFailure: String?

    private var isPlainHTTP: Bool {
        InstanceConfig.normalizedURL(draft.url).lowercased().hasPrefix("http://")
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("instance.name")
                TextField("https://pi.hole", text: $draft.url)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("instance.url")
            } header: {
                Text("Instance")
            } footer: {
                if isPlainHTTP {
                    Text("Plain http sends your password unencrypted. Use https:// if your Pi-hole serves it.")
                        .foregroundStyle(theme.block)
                } else {
                    Text("The address you open for the Pi-hole web admin, such as https://pi.hole or https://10.0.0.53.")
                }
            }
            .rowStyle()

            Section {
                SecureField(existing == nil ? "App password" : "App password (leave blank to keep)", text: $draft.password)
                    .accessibilityIdentifier("instance.password")
            } header: {
                Text("Password")
            } footer: {
                Text("An app password from Pi-hole's web interface settings works best, because it is not subject to two-factor prompts. It is stored in this device's Keychain.")
            }
            .rowStyle()

            Section {
                Toggle("Verify TLS certificate", isOn: $draft.verifyTLS)
            } footer: {
                Text("Turn this off only for a Pi-hole that uses a self-signed certificate.")
            }
            .rowStyle()

            Section {
                Button {
                    Task {
                        await test()
                    }
                } label: {
                    HStack {
                        Text("Test connection")
                        Spacer()
                        if isTesting {
                            ProgressView()
                        } else if testPassed {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(theme.allow)
                                .accessibilityLabel("Connection succeeded")
                        }
                    }
                }
                .disabled(isTesting)
                .accessibilityIdentifier("instance.test")

                if let testFailure {
                    ErrorBanner(message: testFailure)
                }
            }
            .rowStyle()

            if let problem {
                Section {
                    ErrorBanner(message: problem)
                }
                .listRowBackground(Color.clear)
            }

            Section {
                Button {
                    save()
                } label: {
                    Text(existing == nil ? "Add instance" : "Save")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("instance.save")
            }
            .rowStyle()
        }
        .screenStyle()
        .onAppear {
            guard !loadedDraft else {
                return
            }
            loadedDraft = true
            if let existing {
                draft = InstanceDraft(
                    name: existing.name,
                    url: existing.url,
                    password: "",
                    verifyTLS: existing.verifyTLS
                )
            }
        }
    }

    private func save() {
        do {
            try app.saveInstance(id: existing?.id, draft: draft)
            problem = nil
            onSaved()
        } catch {
            problem = error.localizedDescription
        }
    }

    @MainActor
    private func test() async {
        isTesting = true
        testPassed = false
        testFailure = nil
        do {
            try await AppModel.testConnection(draft: draft, existingID: existing?.id)
            testPassed = true
        } catch {
            if !ErrorText.isCancellation(error) {
                testFailure = ErrorText.describe(error)
            }
        }
        isTesting = false
    }
}

/// First run: there is no instance yet, so the only thing to do is add one.
struct OnboardingView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    Text("tihole")
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                        .foregroundStyle(theme.gradient)
                    Text("Your Pi-hole, in your pocket.")
                        .font(.subheadline)
                        .foregroundStyle(theme.subtle)
                }
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                .background(theme.surface)

                InstanceForm(existing: nil)
            }
            .background(theme.surface.ignoresSafeArea())
            .navigationTitle("Welcome")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

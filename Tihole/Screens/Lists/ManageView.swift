import SwiftUI

/// The Lists tab: everything that decides what gets blocked and for whom.
struct ManageView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        List {
            BannerSection(error: app.connectionProblem)

            Section {
                link(
                    "Domains", detail: "Allow and deny lists, exact and regex",
                    icon: "globe"
                ) {
                    DomainsView()
                }
                link(
                    "Adlists", detail: "Subscribed lists and gravity updates",
                    icon: "list.bullet.rectangle.portrait"
                ) {
                    AdlistsView()
                }
            }
            .rowStyle()

            Section {
                link(
                    "Groups", detail: "Scopes for domains, clients, and lists",
                    icon: "square.stack.3d.up"
                ) {
                    GroupsView()
                }
                link(
                    "Clients", detail: "Devices and their group membership",
                    icon: "laptopcomputer.and.iphone"
                ) {
                    ClientsView()
                }
            }
            .rowStyle()

            Section {
                link(
                    "Local DNS", detail: "Host and CNAME records",
                    icon: "signpost.right"
                ) {
                    LocalDNSView()
                }
            }
            .rowStyle()
        }
        .screenStyle()
        .navigationTitle("Lists")
        .navigationBarTitleDisplayMode(.inline)
        .chrome()
    }

    private func link<Destination: View>(
        _ title: String,
        detail: String,
        icon: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(theme.text)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(theme.subtle)
                }
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(theme.accent)
            }
        }
    }
}

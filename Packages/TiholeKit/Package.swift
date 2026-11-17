// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TiholeKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "PiholeKit", targets: ["PiholeKit"]),
        .library(name: "TiholeCore", targets: ["TiholeCore"]),
    ],
    targets: [
        // Pi-hole v6 REST client. The only code that speaks HTTP.
        .target(name: "PiholeKit"),
        // UI-independent app logic: instance config, formatting, config-tree
        // flattening. Depends on the client, never on SwiftUI.
        .target(name: "TiholeCore", dependencies: ["PiholeKit"]),
        .testTarget(name: "PiholeKitTests", dependencies: ["PiholeKit"]),
        .testTarget(name: "TiholeCoreTests", dependencies: ["TiholeCore", "PiholeKit"]),
    ]
)

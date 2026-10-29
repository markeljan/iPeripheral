// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TonyLink",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "TonyLink", targets: ["TonyLink"])],
    targets: [
        .target(name: "TonyLink"),
        .testTarget(name: "TonyLinkTests", dependencies: ["TonyLink"]),
    ]
)

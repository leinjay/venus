// swift-tools-version: 5.9
import PackageDescription

// Foundation-only task rules can be checked without an iOS simulator or model download.
let package = Package(
    name: "VenusTaskCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "VenusTaskCore", targets: ["VenusTaskCore"])],
    targets: [
        .target(name: "VenusTaskCore", path: "VenusTools/Tools/Reminders/Shared"),
        .testTarget(name: "VenusTaskCoreTests", dependencies: ["VenusTaskCore"], path: "Tests/TaskCore")
    ]
)

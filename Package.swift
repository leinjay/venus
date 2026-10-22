// swift-tools-version: 5.9
import PackageDescription

// Foundation-only task rules can be checked without an iOS simulator or model download.
let package = Package(
    name: "VenusTaskCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "VenusTaskCore", targets: ["VenusTaskCore"])],
    targets: [
        .target(name: "VenusTaskCore", path: "VenusTools/Tools/Reminders/Shared"),
        .target(name: "VenusModelCore", path: "VenusTools/iOS/AI", exclude: ["LocalQwenService.swift", "ModelRegistry.swift", "ConfiguredModelService.swift"], sources: ["ModelConfiguration.swift", "ModelWire.swift"]),
        .testTarget(name: "VenusModelCoreTests", dependencies: ["VenusModelCore"], path: "Tests/Models"),
        .testTarget(name: "VenusTaskCoreTests", dependencies: ["VenusTaskCore"], path: "Tests/TaskCore")
    ]
)

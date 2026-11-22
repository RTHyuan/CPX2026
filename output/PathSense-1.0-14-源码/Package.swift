// swift-tools-version: 5.9
import PackageDescription

let package = Package(name: "PathSenseCore", platforms: [.macOS(.v14), .iOS(.v17)], products: [.library(name: "PathSenseCore", targets: ["PathSenseCore"])], targets: [.target(name: "PathSenseCore", path: "Core"), .testTarget(name: "PathSenseCoreTests", dependencies: ["PathSenseCore"], path: "Tests/PathSenseCoreTests")])

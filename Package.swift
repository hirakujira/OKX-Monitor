// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OKXMonitorCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "OKXMonitorCore", targets: ["OKXMonitorCore"])],
    targets: [
        .target(name: "OKXMonitorCore", path: "OKXMonitor/Core"),
        .testTarget(name: "OKXMonitorCoreTests", dependencies: ["OKXMonitorCore"], path: "OKXMonitorTests")
    ]
)

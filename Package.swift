// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Qinglan",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Qinglan", targets: ["Qinglan"])],
    targets: [
        .target(name: "SystemProbe", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "MonitorCore", dependencies: ["SystemProbe"]),
        .executableTarget(name: "Qinglan", dependencies: ["MonitorCore"],
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ServiceManagement")]),
        .executableTarget(name: "MetricsChecks", dependencies: ["MonitorCore", "SystemProbe"], path: "Tests/MonitorCoreTests")
    ]
)

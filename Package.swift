// swift-tools-version: 6.0
import Foundation
import PackageDescription

let commandLineToolsRoot = "/Library/Developer/CommandLineTools"
let needsCommandLineToolsTestingWorkaround = FileManager.default.fileExists(
    atPath: "\(commandLineToolsRoot)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
)

let testSwiftSettings: [SwiftSetting] = needsCommandLineToolsTestingWorkaround ? [
    .unsafeFlags([
        "-F", "\(commandLineToolsRoot)/Library/Developer/Frameworks",
        "-Xfrontend", "-load-plugin-library",
        "-Xfrontend", "\(commandLineToolsRoot)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
    ])
] : []

let testLinkerSettings: [LinkerSetting] = needsCommandLineToolsTestingWorkaround ? [
    .unsafeFlags([
        "-F", "\(commandLineToolsRoot)/Library/Developer/Frameworks",
        "-Xlinker", "-rpath",
        "-Xlinker", "\(commandLineToolsRoot)/Library/Developer/Frameworks",
        "-Xlinker", "-rpath",
        "-Xlinker", "\(commandLineToolsRoot)/Library/Developer/usr/lib",
        "-Xlinker", "-rpath",
        "-Xlinker", "\(commandLineToolsRoot)/usr/lib"
    ])
] : []

let package = Package(
    name: "CoolDownloadManagerMacOS",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CoolDownloadCore", targets: ["CoolDownloadCore"]),
        .library(name: "CoolDownloadIntegration", targets: ["CoolDownloadIntegration"]),
        .executable(name: "CoolDownloadManager", targets: ["CoolDownloadManager"]),
        .executable(name: "CoolDownloadManagerNativeMessagingHost", targets: ["CoolDownloadManagerNativeMessagingHost"]),
        .executable(name: "CoolDownloadManagerCLI", targets: ["CoolDownloadManagerCLI"]),
        .executable(name: "CoolDownloadBenchmark", targets: ["CoolDownloadBenchmark"])
    ],
    targets: [
        .target(
            name: "CoolDownloadCore",
            path: "Sources/CoolDownloadCore"
        ),
        .target(
            name: "CoolDownloadIntegration",
            dependencies: ["CoolDownloadCore"],
            path: "Sources/CoolDownloadIntegration"
        ),
        .executableTarget(
            name: "CoolDownloadManager",
            dependencies: ["CoolDownloadCore", "CoolDownloadIntegration"],
            path: "Sources/CoolDownloadManager"
        ),
        .executableTarget(
            name: "CoolDownloadManagerNativeMessagingHost",
            dependencies: ["CoolDownloadIntegration"],
            path: "Sources/CoolDownloadManagerNativeMessagingHost"
        ),
        .executableTarget(
            name: "CoolDownloadManagerCLI",
            dependencies: ["CoolDownloadCore", "CoolDownloadIntegration"],
            path: "Sources/CoolDownloadManagerCLI"
        ),
        .executableTarget(
            name: "CoolDownloadBenchmark",
            dependencies: ["CoolDownloadCore"],
            path: "Benchmarks/CoolDownloadBenchmark"
        ),
        .testTarget(
            name: "CoolDownloadCoreTests",
            dependencies: ["CoolDownloadCore"],
            path: "Tests/CoolDownloadCoreTests",
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
        .testTarget(
            name: "CoolDownloadIntegrationTests",
            dependencies: ["CoolDownloadIntegration", "CoolDownloadCore"],
            path: "Tests/CoolDownloadIntegrationTests",
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
        .testTarget(
            name: "CoolDownloadManagerTests",
            dependencies: ["CoolDownloadManager", "CoolDownloadCore"],
            path: "Tests/CoolDownloadManagerTests",
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        )
    ],
    swiftLanguageModes: [.v6]
)

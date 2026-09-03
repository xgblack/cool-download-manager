// swift-tools-version: 6.2
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

// SwiftPM links the manager tests against Sparkle.framework but does not copy
// that dynamic framework into the test bundle. The framework is emitted next
// to the test bundle's product directory, so keep the test executable able to
// resolve it without requiring a machine-specific absolute path.
let managerTestLinkerSettings: [LinkerSetting] = testLinkerSettings + [
    .unsafeFlags([
        "-Xlinker", "-rpath",
        "-Xlinker", "@loader_path/../../.."
    ])
]

let package = Package(
    name: "CoolDownloadManagerMacOS",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoolDownloadCore", targets: ["CoolDownloadCore"]),
        .library(name: "CoolDownloadIntegration", targets: ["CoolDownloadIntegration"]),
        .executable(name: "CoolDownloadManager", targets: ["CoolDownloadManager"]),
        .executable(name: "CoolDownloadManagerNativeMessagingHost", targets: ["CoolDownloadManagerNativeMessagingHost"]),
        .executable(name: "CoolDownloadManagerCLI", targets: ["CoolDownloadManagerCLI"]),
        .executable(name: "CoolDownloadBenchmark", targets: ["CoolDownloadBenchmark"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
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
            dependencies: [
                "CoolDownloadCore",
                "CoolDownloadIntegration",
                .product(name: "Sparkle", package: "sparkle")
            ],
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
            dependencies: ["CoolDownloadManager", "CoolDownloadCore", "CoolDownloadIntegration"],
            path: "Tests/CoolDownloadManagerTests",
            swiftSettings: testSwiftSettings,
            linkerSettings: managerTestLinkerSettings
        )
    ],
    swiftLanguageModes: [.v6]
)

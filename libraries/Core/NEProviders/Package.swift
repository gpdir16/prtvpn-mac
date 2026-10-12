// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

enum ProTUNFFITargetKind {
    // 원본은 Proton 내부 Nexus에서 protunFFI를 내려받지만, 외부에서는 접근할 수 없음.
    // Frameworks/protunFFI.xcframework를 직접 넣어둔 경우에만 바이너리 타깃을 선언함.
    static let current: Self = FileManager.default.fileExists(atPath: localFrameworkPath) ? .local : .unavailable

    private static let localFrameworkPath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Frameworks/protunFFI.xcframework")
        .path

    case local
    case remote(url: String, checksum: String)
    case unavailable

    var target: PackageDescription.Target? {
        switch self {
        case .local:
            .binaryTarget(name: "protunFFI", path: "Frameworks/protunFFI.xcframework")
        case let .remote(url, checksum):
            .binaryTarget(name: "protunFFI", url: url, checksum: checksum)
        case .unavailable:
            nil
        }
    }

    /// ProTUNExtension 타깃이 protunFFI를 링크할 때 쓰는 의존성 (iOS 전용)
    var dependencies: [PackageDescription.Target.Dependency] {
        target == nil ? [] : [.target(name: "protunFFI", condition: .when(platforms: [.iOS]))]
    }
}

let swiftLintPluginEnabled: Bool = false
let protunExtensionPlugins: [PackageDescription.Target.PluginUsage] = swiftLintPluginEnabled ? [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")] : []

let package = Package(
    name: "WireGuardExtension",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
    ],
    products: [
        .library(
            name: "ProTUNExtension",
            targets: ["ProTUNExtension"]
        ),
        .library(
            name: "WireGuardExtension",
            targets: ["WireGuardExtension"]
        ),
        .library(
            name: "WireGuardLogging",
            targets: ["WireGuardLogging"]
        ),
        .library(
            name: "WireGuardLoggingC",
            targets: ["WireGuardLoggingC"]
        ),
    ],
    dependencies: [
        .package(name: "WireGuardKit", path: "../../../external/wireguard-apple"),

        .package(path: "../NEHelper"),

        .package(path: "../../Foundations/Ergonomics"),
        .package(path: "../../Foundations/Domain"),
        .package(path: "../../Foundations/PMLogger"),

        .package(path: "../../Shared/ExtensionIPC"),
        .package(path: "../../Shared/Connection"),

        .package(url: "https://github.com/pointfreeco/swift-dependencies", .upToNextMajor(from: "1.4.1")),
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess", exact: "4.2.2"),

        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.62.2"),
    ],
    targets: [
        .target(
            name: "ProTUNExtension",
            dependencies: [
                "Domain",
                "NEHelper",
                .product(name: "NetworkingErgonomics", package: "Ergonomics"),
                .product(name: "ConnectionShared", package: "Connection"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            ] + ProTUNFFITargetKind.current.dependencies,
            plugins: protunExtensionPlugins
        ),
        .target(
            name: "WireGuardLoggingC",
            dependencies: [],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .target(
            name: "WireGuardLogging",
            dependencies: [
                "WireGuardLoggingC",
                "PMLogger",
                .product(name: "Dependencies", package: "swift-dependencies"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .target(
            name: "WireGuardExtension",
            dependencies: [
                "WireGuardKit",
                "WireGuardLogging",
                "ExtensionIPC",
                "NEHelper",
                "KeychainAccess",
                "Ergonomics",
                "Domain",
                .product(name: "VPNShared", package: "NEHelper"),
                .product(name: "CoreConnection", package: "Connection"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "WireGuardExtensionTests",
            dependencies: ["WireGuardExtension"]
        ),
    ] + [ProTUNFFITargetKind.current.target].compactMap(\.self)
)

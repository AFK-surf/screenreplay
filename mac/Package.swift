// swift-tools-version: 6.0
import PackageDescription

let sharedSwiftSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v5),
  .unsafeFlags(["-Xfrontend", "-checked-async-objc-bridging=on"]),
]

let package = Package(
  name: "ScreenReplayMac",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "ScreenReplayKit", targets: ["ScreenReplayKit"]),
    .executable(name: "ScreenReplayHelper", targets: ["ScreenReplayHelper"]),
    .executable(name: "ScreenReplayMac", targets: ["ScreenReplayMac"]),
  ],
  dependencies: [
    .package(path: "vendor/PermissionFlow"),
  ],
  targets: [
    .target(
      name: "ScreenReplayKit",
      dependencies: [
        .product(name: "PermissionFlow", package: "PermissionFlow"),
        .product(name: "SystemSettingsKit", package: "PermissionFlow"),
      ],
      swiftSettings: sharedSwiftSettings
    ),
    .executableTarget(
      name: "ScreenReplayHelper",
      dependencies: ["ScreenReplayKit"],
      swiftSettings: sharedSwiftSettings
    ),
    .executableTarget(
      name: "ScreenReplayMac",
      dependencies: ["ScreenReplayKit"],
      swiftSettings: sharedSwiftSettings,
      linkerSettings: [
        .linkedFramework("Carbon"),
      ]
    ),
    .testTarget(
      name: "ScreenReplayMacTests",
      dependencies: ["ScreenReplayKit"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)

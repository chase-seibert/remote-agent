// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "RemoteAgent",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "RemoteAgent", targets: ["RemoteAgent"])
  ],
  dependencies: [
    .package(path: "../../Packages/RemoteAgentProtocol")
  ],
  targets: [
    .executableTarget(
      name: "RemoteAgent",
      dependencies: ["RemoteAgentProtocol"],
      path: "Sources/RemoteAgent"
    ),
    .testTarget(
      name: "RemoteAgentTests",
      dependencies: ["RemoteAgent"],
      path: "Tests/RemoteAgentTests"
    ),
  ],
  swiftLanguageModes: [.v5]
)

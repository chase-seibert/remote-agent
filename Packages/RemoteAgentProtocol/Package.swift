// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "RemoteAgentProtocol",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(name: "RemoteAgentProtocol", targets: ["RemoteAgentProtocol"])
  ],
  targets: [
    .target(name: "RemoteAgentProtocol"),
    .testTarget(
      name: "RemoteAgentProtocolTests",
      dependencies: ["RemoteAgentProtocol"]
    ),
  ],
  swiftLanguageModes: [.v5]
)

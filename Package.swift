// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "noSpeakerUI",
    platforms: [.macOS(.v12)],
    products: [.executable(name: "noSpeakerUI", targets: ["noSpeakerUI"])],
    targets: [
        .executableTarget(name: "noSpeakerUI", path: "Sources/noSpeakerUI", resources: [.copy("Resources/midi")])
    ]
)

// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "FloatingVoiceFoundation",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "FloatingVoiceCore", targets: ["FloatingVoiceCore"])],
    targets: [.target(name: "FloatingVoiceCore"), .testTarget(name: "FloatingVoiceCoreTests", dependencies: ["FloatingVoiceCore"])],
    swiftLanguageModes: [.v5]
)

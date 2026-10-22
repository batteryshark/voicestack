// swift-tools-version:6.0
import PackageDescription
// Reused accepted interop package; runner stages current tracked native sources.
// ASR-only case, sole serial compiler turn, bounded externally.
let package = Package(
    name: "ActualOpenVoiceEngineInterop",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "FloatingVoiceCore", path: "native/Sources/FloatingVoiceCore"),
        .testTarget(name: "ActualEngineInteropTests", dependencies: ["FloatingVoiceCore"], path: "Tests/ActualEngineInteropTests")
    ],
    swiftLanguageModes: [.v5]
)

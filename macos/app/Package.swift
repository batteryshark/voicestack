// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FloatingVoice",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FloatingVoice", targets: ["FloatingVoice"]),
        .executable(name: "fv-harness", targets: ["fv-harness"]),
    ],
    targets: [
        // OpenChamber client, settings, speech text, ASR/TTS clients, turn-taking and the conversation
        // controller. No audio hardware: audio in and out go through protocols so it runs headless.
        .target(name: "FloatingVoiceCore"),
        // macOS audio: Apple's voice-processing engine (echo cancellation), device selection, playback,
        // and the read-only check for other programs capturing the microphone.
        .target(
            name: "FloatingVoiceAudio",
            dependencies: ["FloatingVoiceCore"],
            linkerSettings: [.linkedFramework("AVFoundation"), .linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox")]
        ),
        // The pill's SwiftUI views (resting pill, card, settings, visualizer), drawn from Core's PillModel. Shared by the
        // app and the harness, which renders still images of the pill's states.
        .target(name: "FloatingVoiceUI", dependencies: ["FloatingVoiceCore"]),
        .executableTarget(name: "FloatingVoice", dependencies: ["FloatingVoiceCore", "FloatingVoiceAudio", "FloatingVoiceUI"]),
        // Headless integration harness: file audio in, recorded audio out, throwaway sessions only.
        .executableTarget(name: "fv-harness", dependencies: ["FloatingVoiceCore", "FloatingVoiceAudio", "FloatingVoiceUI"]),
        .testTarget(name: "FloatingVoiceCoreTests", dependencies: ["FloatingVoiceCore", "FloatingVoiceUI"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)

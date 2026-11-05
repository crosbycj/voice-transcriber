// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoiceTranscriber",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "VoiceTranscriber", targets: ["VoiceApp"]),
        .executable(name: "vt-eval", targets: ["VoiceEval"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.13.6"),
    ],
    targets: [
        .target(
            name: "VTExceptionCatcher",
            path: "Sources/ExceptionCatcher"
        ),
        .target(
            name: "VoiceAudio",
            dependencies: ["VTExceptionCatcher"],
            path: "Sources/Audio"
        ),
        .target(
            name: "VoiceInput",
            path: "Sources/Input"
        ),
        .target(
            name: "VoiceTranscription",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Transcription"
        ),
        .target(
            name: "VoiceCore",
            dependencies: ["VoiceAudio"],
            path: "Sources/Core"
        ),
        .executableTarget(
            name: "VoiceApp",
            dependencies: [
                "VoiceAudio",
                "VoiceCore",
                "VoiceInput",
                "VoiceTranscription",
            ],
            path: "Sources/App"
        ),
        .executableTarget(
            name: "VoiceEval",
            dependencies: [
                "VoiceAudio",
                "VoiceTranscription",
            ],
            path: "Sources/Eval"
        ),
        .testTarget(
            name: "VoiceTests",
            dependencies: [
                "VoiceAudio",
                "VoiceCore",
                "VoiceTranscription",
            ],
            path: "Tests/VoiceTests"
        ),
    ]
)

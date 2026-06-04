// swift-tools-version: 6.0
import PackageDescription

// Whisp — SPM core (all logic, headlessly testable). The macOS .app shell lives in App/
// and consumes these products. Swift 6 language mode (default at tools 6.0) → strict concurrency.
let package = Package(
    name: "Whisp",
    platforms: [.macOS(.v14)], // app target enforces the real 14.4 floor; logic compiles for 14.0+
    products: [
        .library(name: "WhispCore", targets: ["WhispCore"]),
        .library(name: "WhispAudio", targets: ["WhispAudio"]),
        .library(name: "WhispASR", targets: ["WhispASR"]),
        .library(name: "WhispInput", targets: ["WhispInput"]),
        .library(name: "WhispPlatform", targets: ["WhispPlatform"]),
        .library(name: "WhispLLM", targets: ["WhispLLM"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.6.1"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),
        .package(url: "https://github.com/exPHAT/SwiftWhisper.git", branch: "master"),
        // Added per phase:
        // P4 input: .package(url: "https://github.com/tmandry/AXSwift.git", from: "0.3.0"),
        // P10:      .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.2"),
        //           .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern", from: "1.0.0"),
        //           .package(url: "https://github.com/marmelroy/Zip", from: "2.1.0"),
        //           .package(url: "https://github.com/apple/swift-atomics", from: "1.2.0"),
    ],
    targets: [
        .target(name: "WhispPlatform"),
        .target(name: "WhispLLM"),
        .target(name: "WhispAudio", dependencies: ["WhispPlatform"]),
        .target(name: "WhispInput", dependencies: ["WhispPlatform"]),
        .target(
            name: "WhispASR",
            dependencies: [
                "WhispAudio", "WhispPlatform",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "SwiftWhisper", package: "SwiftWhisper"),
            ]),
        .target(
            name: "WhispCore",
            dependencies: ["WhispAudio", "WhispASR", "WhispInput", "WhispPlatform", "WhispLLM"]
        ),
        .testTarget(
            name: "WhispCoreTests",
            dependencies: ["WhispCore", "WhispAudio", "WhispASR", "WhispInput", "WhispPlatform"]),
        .testTarget(name: "WhispAudioTests", dependencies: ["WhispAudio"]),
        .testTarget(name: "WhispASRTests", dependencies: ["WhispASR", "WhispAudio"]),
        .testTarget(name: "WhispInputTests", dependencies: ["WhispInput"]),
        .testTarget(name: "WhispLLMTests", dependencies: ["WhispLLM"]),
    ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PopinVRTracking",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "PopinVRTracking", targets: ["PopinVRTracking"])
    ],
    dependencies: [
        .package(url: "https://github.com/google-ai-edge/mediapipe", branch: "master")
    ],
    targets: [
        .target(
            name: "PopinVRTracking",
            dependencies: [.product(name: "MediaPipeTasksVision", package: "mediapipe")]
        )
    ]
)

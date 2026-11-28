// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PopinVRTracking",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "PopinVRTracking",
            targets: ["PopinVRTracking"]
        )
    ],
    targets: [
        .target(
            name: "PopinVRTracking"
        )
    ]
)

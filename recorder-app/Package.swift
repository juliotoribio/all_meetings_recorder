// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "RecorderJT",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(
            name: "RecorderJT",
            path: "Sources/RecorderJT",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
            ]
        )
    ]
)

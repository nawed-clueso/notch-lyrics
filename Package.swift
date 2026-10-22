// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NotchLyrics",
    platforms: [.macOS(.v15)],   // MeshGradient + modern color effects
    targets: [
        // Tiny ObjC shim so AVFoundation's NSExceptions can be turned into
        // Swift errors instead of terminating the process.
        .target(
            name: "ObjCGuard",
            path: "Sources/ObjCGuard",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "NotchLyrics",
            dependencies: ["ObjCGuard"],
            path: "Sources/NotchLyrics",
            resources: [
                .copy("Resources/InstrumentSerif-Regular.ttf"),
                .copy("Resources/WorkSans-Regular.ttf"),
                .copy("Resources/WorkSans-SemiBold.ttf"),
                .copy("Resources/GeistMono-Regular.otf"),
                .copy("Resources/GeistMono-Medium.otf"),
                .copy("Resources/GeistMono-SemiBold.otf"),
                .copy("Resources/web")
            ]
        )
    ]
)

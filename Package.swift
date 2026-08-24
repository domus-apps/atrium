// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Atrium",
    /* macOS 26+ renders apps linked against an older SDK in the legacy
       compatibility design (old-style traffic lights, pre-Liquid Glass
       chrome). This toolchain stamps the binary's LC_BUILD_VERSION sdk field
       from the deployment target, so the target must be >= 26 for the app
       to get the native current-OS appearance. */
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Atrium",
            path: "Sources/Atrium"
        ),
        .testTarget(
            name: "AtriumTests",
            dependencies: ["Atrium"],
            path: "Tests/AtriumTests"
        )
    ]
)

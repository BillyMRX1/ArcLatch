// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ArcLatch",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ArcLatchCore"),
        .executableTarget(
            name: "ArcLatchApp",
            dependencies: ["ArcLatchCore"]
        ),
        .testTarget(
            name: "ArcLatchCoreTests",
            dependencies: ["ArcLatchCore"],
            // This CLT ships TestingMacros under plugins/testing/, where the
            // compiler's implicit plugin resolution does not look; a symlink
            // in the flat plugins/ directory fixes that system-wide (see
            // memory/toolchain notes). The explicit load below is the
            // fallback for jobs that honor target flags. XCTest is not in
            // the CLT, so Swift Testing is the only test library available.
            // If a CLT update wipes the symlink, plain `swift test` breaks
            // again; recreate it, or run: SWIFT_ENABLE_EXPLICIT_MODULES=NO swift test
            swiftSettings: [
                .unsafeFlags([
                    "-load-resolved-plugin",
                    "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib##TestingMacros",
                ]),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)

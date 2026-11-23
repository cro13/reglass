// swift-tools-version: 5.10
// ReGlassKit: ReGlass's own engine for Ray-Ban Meta glasses — Bluetooth, the encrypted link, Meta sign-in,
// ownership, live status, the wake word and the glasses' assistant service. See DESIGN.md.
import PackageDescription

let package = Package(
    name: "ReGlassKit",
    platforms: [.iOS("27.0"), .macOS(.v14)],
    products: [
        .library(name: "ReGlassKit", targets: ["ReGlassKit"]),
    ],
    dependencies: [
        // libopus, the one third-party dependency: the Audio glasses play only CELT-only CBR replies, and Apple's
        // Opus encoder has no control for that. Source only, pinned exactly.
        .package(url: "https://github.com/alta/swift-opus.git", exact: "0.0.2"),
    ],
    targets: [
        // A typed C bridge to libopus: Swift cannot call the variadic opus_encoder_ctl.
        .target(name: "ReGlassOpus", dependencies: [.product(name: "Copus", package: "swift-opus")]),
        .target(
            name: "ReGlassKit",
            dependencies: ["ReGlassOpus"],
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)

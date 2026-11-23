// swift-tools-version: 5.10
// ReGlassAssistant: the brain and voice of ReGlass's assistant. Claude over raw HTTPS and SSE, ElevenLabs and Apple
// voices, on-device speech-to-text, the Keychain key store, and the turn runner that joins them. No third-party
// dependencies and no dependency on ReGlassKit: the app connects the two.
import PackageDescription

let package = Package(
    name: "ReGlassAssistant",
    platforms: [.iOS("27.0"), .macOS("26.0")],
    products: [
        .library(name: "ReGlassAssistant", targets: ["ReGlassAssistant"]),
    ],
    targets: [
        .target(name: "ReGlassAssistant"),
    ]
)

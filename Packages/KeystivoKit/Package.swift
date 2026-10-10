// swift-tools-version: 6.2
import PackageDescription

/// Settings shared by every Swift target: Swift 6 language mode with main-actor
/// default isolation (UI-centric code), plus the "approachable concurrency" features.
let swiftSettings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
]

func module(
    _ name: String,
    dependencies: [Target.Dependency] = [],
    resources: [Resource]? = nil,
    linkerSettings: [LinkerSetting] = []
) -> Target {
    .target(
        name: name,
        dependencies: dependencies,
        resources: resources,
        swiftSettings: swiftSettings,
        linkerSettings: linkerSettings
    )
}

func tests(_ name: String, dependencies: [Target.Dependency]) -> Target {
    .testTarget(name: name, dependencies: dependencies, swiftSettings: swiftSettings)
}

let package = Package(
    name: "KeystivoKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "KeystivoKit", targets: ["KeystivoApp"]),
        // Linked by the privileged helper tool (charge limiting).
        .library(name: "KeystivoHelperKit", targets: ["KeystivoHelperCore"]),
    ],
    targets: [
        // MARK: Foundation layer
        module("KeystivoCore", resources: [.process("Resources")]),
        .target(name: "CMultitouch", path: "Sources/CMultitouch"),
        module("KeystivoAccessibility", dependencies: ["KeystivoCore"]),

        // MARK: Feature modules (independently testable)
        module("KeystivoWindows", dependencies: ["KeystivoCore", "KeystivoAccessibility"]),
        module("KeystivoNavigation", dependencies: ["KeystivoCore", "KeystivoAccessibility"]),
        module("KeystivoAudio", dependencies: ["KeystivoCore"]),
        module("KeystivoClipboard", dependencies: ["KeystivoCore"]),
        module("KeystivoSearch", dependencies: ["KeystivoCore"]),
        module("KeystivoInput", dependencies: ["KeystivoCore", "CMultitouch"]),
        module("KeystivoAutomation", dependencies: ["KeystivoCore"]),
        module("KeystivoSystem", dependencies: ["KeystivoCore", "KeystivoAccessibility"]),
        module("KeystivoPlugins", dependencies: ["KeystivoCore"], resources: [.copy("Resources/Examples.keystivoplugin")]),
        module("KeystivoTools", dependencies: ["KeystivoCore"]),
        module("KeystivoFiles", dependencies: ["KeystivoCore"]),
        module("KeystivoLinks", dependencies: ["KeystivoCore"]),
        // Self-contained: also compiled into the standalone .saver bundles.
        module("KeystivoScreenSaver"),

        // MARK: Privileged helper support (no main-actor default: runs on XPC queues)
        .target(name: "CSMC", path: "Sources/CSMC", linkerSettings: [.linkedFramework("IOKit")]),
        .target(
            name: "KeystivoHelperCore",
            dependencies: ["CSMC"],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),

        // MARK: Composition root: runtime wiring + all user interface
        module("KeystivoApp", dependencies: [
            "KeystivoCore", "KeystivoAccessibility", "KeystivoWindows", "KeystivoNavigation",
            "KeystivoAudio", "KeystivoClipboard", "KeystivoSearch", "KeystivoInput",
            "KeystivoAutomation", "KeystivoSystem", "KeystivoPlugins",
            "KeystivoTools", "KeystivoFiles", "KeystivoLinks", "KeystivoHelperCore", "KeystivoScreenSaver",
        ]),

        // MARK: Tests
        tests("KeystivoCoreTests", dependencies: ["KeystivoCore"]),
        tests("KeystivoWindowsTests", dependencies: ["KeystivoWindows"]),
        tests("KeystivoNavigationTests", dependencies: ["KeystivoNavigation"]),
        tests("KeystivoSearchTests", dependencies: ["KeystivoSearch"]),
        tests("KeystivoInputTests", dependencies: ["KeystivoInput"]),
        tests("KeystivoAutomationTests", dependencies: ["KeystivoAutomation"]),
        tests("KeystivoClipboardTests", dependencies: ["KeystivoClipboard"]),
        tests("KeystivoPluginsTests", dependencies: ["KeystivoPlugins"]),
        tests("KeystivoAudioTests", dependencies: ["KeystivoAudio"]),
        tests("KeystivoSystemTests", dependencies: ["KeystivoSystem"]),
        tests("KeystivoToolsTests", dependencies: ["KeystivoTools"]),
        tests("KeystivoFilesTests", dependencies: ["KeystivoFiles"]),
        tests("KeystivoLinksTests", dependencies: ["KeystivoLinks"]),
        tests("KeystivoScreenSaverTests", dependencies: ["KeystivoScreenSaver"]),
        .testTarget(name: "KeystivoHelperCoreTests", dependencies: ["KeystivoHelperCore"]),
    ]
)

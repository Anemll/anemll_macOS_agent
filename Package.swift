// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AnemllAgentCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AnemllAgentCore", targets: ["AnemllAgentCore"])
    ],
    targets: [
        .target(
            name: "AnemllAgentCore",
            path: "AnemllAgentHost",
            exclude: [
                "AccessibilityAutomation.swift", "AnemllAgentHostApp.swift", "AppDelegate.swift",
                "Assets.xcassets", "ContentView.swift", "CursorOverlay.swift", "HostViewModel.swift",
                "Info.plist", "LocalHTTPServer.swift", "ScreenAndInput.swift", "ScreenCaptureBackend.swift",
                "skills"
            ],
            sources: ["AgentIntegration.swift", "AutomationCore.swift", "HTTPTypes.swift"]
        ),
        .testTarget(
            name: "AnemllAgentCoreTests",
            dependencies: ["AnemllAgentCore"],
            path: "Tests/AnemllAgentCoreTests"
        )
    ]
)

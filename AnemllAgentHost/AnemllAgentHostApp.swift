import SwiftUI

@main
struct AnemllAgentHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No windows; menu bar only
        Settings {
            EmptyView()
        }
    }
}

import AppKit
import SwiftUI

@main
struct TaskManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = PerformanceMonitor()

    var body: some Scene {
        WindowGroup("Task Manager") {
            ContentView()
                .environmentObject(monitor)
                .frame(minWidth: 980, minHeight: 660)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched with `swift run`, which has no app bundle. A bundled app is
        // activated by the system, which also lets `open -g` keep it in the background.
        guard Bundle.main.bundleIdentifier == nil else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

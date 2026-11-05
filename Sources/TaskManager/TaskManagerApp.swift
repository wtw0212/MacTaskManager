import AppKit
import SwiftUI

@main
struct TaskManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = PerformanceMonitor()

    var body: some Scene {
        WindowGroup("Task Manager") {
            PerformanceView()
                .environmentObject(monitor)
                .frame(minWidth: 860, minHeight: 580)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched with `swift run`, which has no app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

import AppKit
import SwiftUI

@main
struct TaskManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = PerformanceMonitor()
    @AppStorage(AppPreferences.alwaysOnTopKey) private var alwaysOnTop = false
    @AppStorage(AppPreferences.graphSummaryKey) private var graphSummary = false

    var body: some Scene {
        WindowGroup("Task Manager") {
            ContentView(monitor: monitor)
                .environmentObject(monitor)
                .frame(minWidth: 980, minHeight: 660)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Windows' File, Options and View menus, in their macOS places.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { Self.show(.settings) }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("Run new task…") { RunNewTask.present() }.keyboardShortcut("n")
            }
            CommandGroup(before: .toolbar) {
                Button("Refresh now") { monitor.refreshNow() }.keyboardShortcut("r")
                Picker("Update speed", selection: $monitor.updateSpeed) {
                    ForEach(UpdateSpeed.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Graph summary view", isOn: $graphSummary)
                Divider()
                ForEach(ContentView.Page.main) { page in
                    Button(page.rawValue) { Self.show(page) }
                }
                Divider()
            }
            CommandGroup(after: .windowArrangement) {
                Toggle("Always on top", isOn: $alwaysOnTop)
            }
        }
    }

    /// Switches pages from the menu bar (ContentView keeps the page in user defaults).
    private static func show(_ page: ContentView.Page) {
        UserDefaults.standard.set(page.rawValue, forKey: "selectedPage")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppHistory.shared.start()
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

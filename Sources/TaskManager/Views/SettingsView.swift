import AppKit
import ApplicationServices
import SwiftUI

/// Windows' App theme setting.
enum AppTheme: String, CaseIterable, Identifiable {
    case system = "Use system setting", light = "Light", dark = "Dark"

    var id: Self { self }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Settings that act on the app window rather than on one page.
enum AppPreferences {
    static let startPageKey = "startPage"
    static let themeKey = "appTheme"
    static let alwaysOnTopKey = "alwaysOnTop"
    static let graphSummaryKey = "graphSummaryView"

    @MainActor
    static func apply(theme: AppTheme, alwaysOnTop: Bool) {
        let update = {
            NSApp.appearance = theme.appearance
            for window in NSApp.windows where window.styleMask.contains(.titled) && !(window is NSPanel) {
                window.level = alwaysOnTop ? .floating : .normal
            }
        }
        update()
        // The window may not be on screen yet when the app starts.
        DispatchQueue.main.async(execute: update)
    }
}

/// Windows' Settings page.
struct SettingsView: View {
    @EnvironmentObject private var monitor: PerformanceMonitor
    @ObservedObject private var helper = PrivilegedHelper.shared
    @AppStorage(AppPreferences.startPageKey) private var startPage = ""
    @AppStorage(AppPreferences.themeKey) private var theme = AppTheme.system
    @AppStorage(AppPreferences.alwaysOnTopKey) private var alwaysOnTop = false
    @AppStorage(HangDetector.enabledKey) private var detectHangs = true
    @AppStorage("helperBannerDismissed") private var bannerDismissed = false
    @State private var accessibilityAllowed = AXIsProcessTrusted()

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Settings") {}

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    general
                    systemProcesses
                    about
                }
                .padding(DS.Space.xl)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onReceive(refresh) { _ in accessibilityAllowed = AXIsProcessTrusted() }
    }

    private var general: some View {
        SettingsSection(title: "General") {
            SettingsRow(title: "Default start page", detail: "The page Task Manager opens on.") {
                Picker("Default start page", selection: $startPage) {
                    Text("Last page used").tag("")
                    ForEach(ContentView.Page.main) { Text($0.rawValue).tag($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(title: "Real time update speed", detail: "How often the numbers and graphs update. Paused stops updating.") {
                Picker("Real time update speed", selection: $monitor.updateSpeed) {
                    ForEach(UpdateSpeed.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(title: "App theme") {
                Picker("App theme", selection: $theme) {
                    ForEach(AppTheme.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(title: "Always on top", detail: "Keeps the Task Manager window above other windows.") {
                Toggle("Always on top", isOn: $alwaysOnTop).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    private var systemProcesses: some View {
        SettingsSection(title: "System processes") {
            SettingsRow(title: "Privileged helper", detail: helperDetail) {
                HStack(spacing: DS.Space.s) {
                    switch helper.state {
                    case .running:
                        Button("Remove") { helper.uninstall() }
                    case .installing:
                        ProgressView().controlSize(.small)
                    case .outdated:
                        Button("Update") { helper.install() }
                    case .notInstalled, .failed:
                        Button("Install") {
                            bannerDismissed = false
                            helper.install()
                        }
                    }
                }
            }
            SettingsRow(title: "Show apps that aren't responding",
                        detail: accessibilityAllowed
                            ? "Asks each app for its window title with a one-second timeout; an app that doesn't answer shows as Not responding."
                            : "Needs the Accessibility permission: macOS has no other way for apps to tell. Allow Task Manager in Privacy & Security > Accessibility.") {
                HStack(spacing: DS.Space.s) {
                    if !accessibilityAllowed {
                        Button("Allow…") { requestAccessibility() }
                    }
                    Toggle("Show apps that aren't responding", isOn: $detectHangs).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }

    private var about: some View {
        SettingsSection(title: "About") {
            SettingsRow(title: "Task Manager", detail: "Version \(Self.version)") { EmptyView() }
            SettingsRow(title: "Credits",
                        detail: "Icons: Fluent UI System Icons by Microsoft (MIT License). The privileged helper, Details actions and hang detection are adapted from task-manager-for-mac by Yatin Arora (MIT License).") {
                Button("Licenses") { openLicenses() }
            }
        }
    }

    private var helperDetail: String {
        switch helper.state {
        case .running:
            "Installed. Task Manager can read and control processes owned by root and other users, such as WindowServer."
        case .installing:
            "Waiting for the administrator password…"
        case .outdated:
            "Installed from an older version of Task Manager. Update it to keep reading system processes."
        case .notInstalled:
            "Without it, processes owned by root and other users show no CPU or memory, and can't be ended or changed. Installing asks for an administrator password once. The helper is a small setuid tool in /Library/Application Support/MacTaskManager that only administrators can use."
        case .failed(let reason):
            "Couldn't use the helper: \(reason)"
        }
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"
    }

    private func requestAccessibility() {
        // Shows macOS's own prompt, which offers to open System Settings.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openLicenses() {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("LICENSES")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) {
            NSWorkspace.shared.open(bundled)
        } else if let url = URL(string: "https://github.com/yatindma/task-manager-for-mac/blob/main/LICENSE") {
            NSWorkspace.shared.open(url)
        }
    }
}

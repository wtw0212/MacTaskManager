import AppKit
import SwiftUI

/// An alert shown by the process pages: a plain message, or a confirmation with a destructive button.
struct ProcessAlert {
    var title: String
    var message: String
    /// Destructive confirmation button; nil for a plain OK alert.
    var confirm: String?
    var action: () -> Void = {}

    /// Windows' confirmation before End process tree, which then ends the whole tree.
    @MainActor
    static func endProcessTree(_ row: ProcessRow, then done: @escaping () -> Void) -> ProcessAlert {
        ProcessAlert(
            title: "End the process tree of \(row.name)?",
            message: "This ends the process and every process it started. Unsaved data in them will be lost, and ending a system process may make macOS unstable.",
            confirm: "End process tree",
            action: {
                if let error = ProcessSampler.terminateTree(row.id) {
                    NSAlert.show("Couldn't end the whole process tree", "\(error). Some of its processes may belong to another user: install the helper in Settings to end those.")
                }
                done()
            }
        )
    }
}

extension View {
    func processAlert(_ alert: Binding<ProcessAlert?>) -> some View {
        self.alert(alert.wrappedValue?.title ?? "", isPresented: Binding(get: { alert.wrappedValue != nil },
                                                                        set: { if !$0 { alert.wrappedValue = nil } }),
                   presenting: alert.wrappedValue) { alert in
            if let confirm = alert.confirm {
                Button(confirm, role: .destructive, action: alert.action)
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK") {}
            }
        } message: { Text($0.message) }
    }
}

extension NSAlert {
    @MainActor
    static func show(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

/// "Go to details": opens the Details page with a process selected.
enum DetailsNavigation {
    static let selectionKey = "detailsSelectedPID"

    static func show(_ pid: pid_t) {
        UserDefaults.standard.set(Int(pid), forKey: selectionKey)
        UserDefaults.standard.set(ContentView.Page.details.rawValue, forKey: "selectedPage")
    }
}

/// Offers the privileged helper above the process lists while other users' processes can't be read.
struct HelperBanner: View {
    @ObservedObject private var helper = PrivilegedHelper.shared
    @AppStorage("helperBannerDismissed") private var dismissed = false

    var body: some View {
        if !dismissed, helper.state != .running {
            VStack(spacing: 0) {
                HStack(spacing: DS.Space.m) {
                    Fluent(.shield, size: DS.Size.icon).foregroundStyle(.secondary)
                    Text(message)
                        .font(DS.Typeface.body)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: DS.Space.s)
                    if helper.state != .installing {
                        Button(helper.state == .outdated ? "Update helper" : "Install helper") { helper.install() }
                    }
                    Button { dismissed = true } label: { Fluent(.dismiss, size: 12).foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .help("Hide. You can install the helper later in Settings.")
                }
                .padding(.horizontal, DS.Space.xl)
                .padding(.vertical, DS.Space.s)
                Rectangle().fill(DS.Palette.stroke).frame(height: 1)
            }
        }
    }

    private var message: String {
        switch helper.state {
        case .installing: "Installing the helper…"
        case .outdated: "The helper is from an older version of Task Manager. Update it to see system processes again."
        case .failed(let reason): "Couldn't use the helper: \(reason)"
        default: "System processes such as WindowServer show no CPU or memory. A small helper can read them; macOS asks for your password once."
        }
    }
}

/// Windows' "Create new task" dialog: open an app, file, folder, website or command, optionally as an administrator.
enum RunNewTask {
    @MainActor
    static func present() {
        let alert = NSAlert()
        alert.messageText = "Create new task"
        alert.informativeText = "Type the name of an app, a program, a folder, a document or a website, and Task Manager will open it."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Browse…")

        let field = NSTextField(frame: NSRect(x: 0, y: 30, width: 340, height: 24))
        field.placeholderString = "Open: for example Safari, ~/Documents or https://apple.com"
        let admin = NSButton(checkboxWithTitle: "Create this task with administrative privileges", target: nil, action: nil)
        admin.frame = NSRect(x: 0, y: 0, width: 340, height: 20)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 56))
        container.addSubview(field)
        container.addSubview(admin)
        alert.accessoryView = container
        alert.window.initialFirstResponder = field

        while true {
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if let error = run(field.stringValue, asAdministrator: admin.state == .on) {
                    NSAlert.show("Couldn't create the task", error)
                }
                return
            case .alertThirdButtonReturn:
                let panel = NSOpenPanel()
                panel.title = "Browse"
                panel.directoryURL = URL(fileURLWithPath: "/Applications")
                panel.canChooseDirectories = true
                panel.treatsFilePackagesAsDirectories = false
                if panel.runModal() == .OK, let url = panel.url { field.stringValue = url.path }
            default:
                return
            }
        }
    }

    /// Opens or runs `text`. Returns an error message, or nil when it started.
    @MainActor
    static func run(_ text: String, asAdministrator: Bool) -> String? {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }
        let path = (command as NSString).expandingTildeInPath
        let exists = FileManager.default.fileExists(atPath: path)
        let url = URL(string: command).flatMap { $0.scheme != nil && command.contains(":") ? $0 : nil }

        if asAdministrator {
            // Paths and websites are opened, anything else runs as a shell command, as root.
            let line = exists || url != nil ? "/usr/bin/open \(Shell.shellQuoted(exists ? path : command))" : command
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Shell.runAsAdministrator("/bin/sh", ["-c", line])
                // -128: the password prompt was cancelled.
                guard result.status != 0, !result.output.contains("-128") else { return }
                DispatchQueue.main.async { NSAlert.show("Couldn't create the task", result.output) }
            }
            return nil
        }

        if exists {
            let fileURL = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            if !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: path) {
                return launch(path, [])
            }
            if fileURL.pathExtension == "app" {
                NSWorkspace.shared.openApplication(at: fileURL, configuration: .init())
            } else {
                NSWorkspace.shared.open(fileURL)
            }
            return nil
        }
        if let url {
            return NSWorkspace.shared.open(url) ? nil : "Nothing can open \(command)."
        }
        if let app = application(named: command) {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
            return nil
        }
        let program = command.split(separator: " ").first.map(String.init) ?? command
        guard Shell.run("/bin/sh", ["-c", "command -v \(Shell.shellQuoted(program))"]).status == 0 else {
            return "Task Manager can't find '\(command)'. Make sure you typed the name correctly, and then try again."
        }
        return launch("/bin/sh", ["-c", command])
    }

    private static func launch(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// An app by bundle identifier or by name, as Spotlight would find it in the usual folders.
    private static func application(named name: String) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) { return url }
        let file = name.hasSuffix(".app") ? name : name + ".app"
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                       "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        return folders.map { URL(fileURLWithPath: $0).appendingPathComponent(file) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

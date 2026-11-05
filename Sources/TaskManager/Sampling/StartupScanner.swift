import Foundation

/// A launchd job that starts automatically: the macOS equivalent of a Windows startup app.
struct StartupItem: Identifiable {
    enum Scope: String {
        case user = "This user (LaunchAgent)"
        case allUsers = "All users (LaunchAgent)"
        case system = "System (LaunchDaemon)"
    }

    var id: String { plistPath }
    var label: String
    var program: String?
    var plistPath: String
    var scope: Scope
    var runAtLoad: Bool
    var keepAlive: Bool
    var isDisabled: Bool
    var isRunning: Bool

    var name: String {
        guard let program else { return label }
        if let app = program.components(separatedBy: "/").first(where: { $0.hasSuffix(".app") }) {
            return String(app.dropLast(4))
        }
        return (program as NSString).lastPathComponent
    }

    /// Developer guess from a reverse-DNS label, e.g. "com.google.keystone.agent" -> "google".
    var publisher: String {
        let parts = label.split(separator: ".")
        return parts.count >= 2 ? String(parts[1]) : ""
    }

    var domainTarget: String {
        scope == .system ? "system/\(label)" : "gui/\(getuid())/\(label)"
    }
}

enum StartupScanner {
    static func scan() -> [StartupItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders: [(String, StartupItem.Scope)] = [
            ("\(home)/Library/LaunchAgents", .user),
            ("/Library/LaunchAgents", .allUsers),
            ("/Library/LaunchDaemons", .system),
        ]
        let disabledGUI = disabledLabels(domain: "gui/\(getuid())")
        let disabledSystem = disabledLabels(domain: "system")
        let running = runningLabels()

        var items: [StartupItem] = []
        for (folder, scope) in folders {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for file in files where file.hasSuffix(".plist") {
                let path = "\(folder)/\(file)"
                guard let data = FileManager.default.contents(atPath: path),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let label = plist["Label"] as? String else { continue }

                // Prefer the .app an `open -a …` style agent launches over the launcher itself.
                let arguments = plist["ProgramArguments"] as? [String] ?? []
                let program = plist["Program"] as? String
                    ?? arguments.first { $0.contains(".app/") || $0.hasSuffix(".app") }
                    ?? arguments.first
                let keepAlive: Bool = {
                    if let flag = plist["KeepAlive"] as? Bool { return flag }
                    return plist["KeepAlive"] is [String: Any]
                }()
                let overrides = scope == .system ? disabledSystem : disabledGUI
                let isDisabled = overrides[label] ?? (plist["Disabled"] as? Bool ?? false)

                items.append(StartupItem(
                    label: label,
                    program: program,
                    plistPath: path,
                    scope: scope,
                    runAtLoad: plist["RunAtLoad"] as? Bool ?? false,
                    keepAlive: keepAlive,
                    isDisabled: isDisabled,
                    isRunning: running.contains(label)
                ))
            }
        }
        return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Enables or disables an item with `launchctl enable/disable`. This sets launchd's
    /// override, so the job won't start at the next login or boot; it doesn't stop it now.
    /// System daemons need an administrator password.
    @discardableResult
    static func setEnabled(_ enabled: Bool, for item: StartupItem) -> Bool {
        let verb = enabled ? "enable" : "disable"
        if item.scope == .system {
            let command = "/bin/launchctl \(verb) \(item.domainTarget)"
            let script = "do shell script \"\(command)\" with administrator privileges"
            return run("/usr/bin/osascript", ["-e", script]).status == 0
        }
        return run("/bin/launchctl", [verb, item.domainTarget]).status == 0
    }

    private static func disabledLabels(domain: String) -> [String: Bool] {
        // Lines look like: "com.example.agent" => disabled   (or => true / => enabled / => false)
        var result: [String: Bool] = [:]
        for line in run("/bin/launchctl", ["print-disabled", domain]).output.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            result[label] = value == "disabled" || value == "true"
        }
        return result
    }

    private static func runningLabels() -> Set<String> {
        // `launchctl list` prints "PID  Status  Label"; a number in the PID column means running.
        var labels = Set<String>()
        for line in run("/bin/launchctl", ["list"]).output.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: "\t")
            if columns.count == 3, Int(columns[0]) != nil {
                labels.insert(String(columns[2]))
            }
        }
        return labels
    }

    private static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

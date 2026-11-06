import Combine
import Foundation

/// A launchd service, the macOS equivalent of a Windows service.
struct ServiceItem: Identifiable, Equatable {
    enum Domain: String { case user = "User", system = "System" }

    var label: String
    var pid: pid_t
    var domain: Domain
    var program: String?

    var id: String { "\(domain.rawValue)/\(label)" }
    var isRunning: Bool { pid > 0 }
    var target: String { domain == .system ? "system/\(label)" : "gui/\(getuid())/\(label)" }
}

enum ServiceScanner {
    enum Action: String {
        case start = "Start", stop = "Stop", restart = "Restart"

        func arguments(_ target: String) -> [String] {
            switch self {
            case .start: ["kickstart", target]
            case .stop: ["kill", "SIGTERM", target]
            case .restart: ["kickstart", "-k", target]
            }
        }
    }

    static func scan(programs: [String: String]) -> [ServiceItem] {
        let domains: [(String, ServiceItem.Domain)] = [("gui/\(getuid())", .user), ("system", .system)]
        return domains.flatMap { name, domain in
            parse(Shell.run("/bin/launchctl", ["print", name]).output).map { entry in
                ServiceItem(label: entry.label, pid: entry.pid, domain: domain,
                            program: programs[entry.label] ?? path(of: entry.pid))
            }
        }
    }

    /// Reads a service's line from the `services = { … }` block of `launchctl print`:
    /// "PID  last-exit-status  label".
    static func parse(_ output: String) -> [(label: String, pid: pid_t)] {
        var inServices = false
        var entries: [(label: String, pid: pid_t)] = []
        for line in output.split(separator: "\n") {
            if line == "\tservices = {" {
                inServices = true
            } else if inServices {
                if line == "\t}" { break }
                let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
                if fields.count == 3, let pid = pid_t(fields[0]) {
                    entries.append((fields[2].trimmingCharacters(in: .whitespaces), pid))
                }
            }
        }
        return entries
    }

    /// Program of every launchd plist, by label.
    static func programs() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var result: [String: String] = [:]
        for folder in ["\(home)/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons",
                       "/System/Library/LaunchAgents", "/System/Library/LaunchDaemons"] {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where file.hasSuffix(".plist") {
                guard let data = FileManager.default.contents(atPath: "\(folder)/\(file)"),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let label = plist["Label"] as? String,
                      let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first else { continue }
                result[label] = program
            }
        }
        return result
    }

    private static func path(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
    }
}

/// Keeps the service list fresh every 5 s while the Services page is on screen.
@MainActor
final class ServicesModel: ObservableObject {
    @Published private(set) var items: [ServiceItem] = []
    @Published private(set) var message: String?

    private let queue = DispatchQueue(label: "ServicesModel", qos: .utility, autoreleaseFrequency: .workItem)
    nonisolated(unsafe) private var programs: [String: String]? // only touched on `queue`
    private var timer: AnyCancellable?

    func start() {
        assert(ServiceScanner.parse("x\n\tservices = {\n\t\t  12   (pe) \ta.b c\n\t\t   0   - \td\n\t}\n\t\t  1 2 3").map(\.label) == ["a.b c", "d"])
        refresh()
        timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer = nil
    }

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let programs = self.programs ?? ServiceScanner.programs()
            self.programs = programs
            let items = ServiceScanner.scan(programs: programs)
            DispatchQueue.main.async { if self.items != items { self.items = items } }
        }
    }

    /// Runs off the main thread: a system service waits for the administrator password.
    func perform(_ action: ServiceScanner.Action, on item: ServiceItem) {
        let arguments = action.arguments(item.target)
        queue.async { [weak self] in
            let result = item.domain == .system
                ? Shell.runAsAdministrator("/bin/launchctl", arguments)
                : Shell.run("/bin/launchctl", arguments)
            let detail = result.output.split(separator: "\n").last.map(String.init) ?? ""
            let text = result.status == 0 ? "\(action.rawValue): \(item.label)" : "Couldn't \(action.rawValue.lowercased()) \(item.label). \(detail)"
            DispatchQueue.main.async {
                self?.message = text
                self?.refresh()
            }
        }
    }
}

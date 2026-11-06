import AppKit
import SwiftUI
import SystemConfiguration

/// Windows' Users page: one row per user with the summed usage of their processes.
/// Expanding a user lists their processes. Signed-in people come first, then system accounts
/// (root and the `_` daemons), whose processes can't be read without root, so their totals are partial.
struct UsersView: View {
    private struct UserSection {
        var title: String
        var groups: [ProcessGroup]
    }

    var search: String

    @EnvironmentObject private var monitor: PerformanceMonitor
    @State private var selection: pid_t?
    @State private var expanded: Set<pid_t> = []
    /// nil sorts by name.
    @State private var sortColumn: ProcessColumn?
    @State private var ascending = true

    @AppStorage("memoryAsPercent") private var memoryAsPercent = false
    @AppStorage("diskAsPercent") private var diskAsPercent = false
    @AppStorage("networkAsPercent") private var networkAsPercent = false

    private static let columns: [ProcessColumn] = [.status, .cpu, .memory, .disk, .network, .energy]

    var body: some View {
        let context = ProcessContext(monitor: monitor, memoryAsPercent: memoryAsPercent,
                                     diskAsPercent: diskAsPercent, networkAsPercent: networkAsPercent)
        let sections = self.sections(context)
        let selectedProcess = selection.flatMap { id in monitor.processes.first { $0.id == id } }

        VStack(spacing: 0) {
            PageHeader(title: "Users") {
                CommandButton(title: "End task", icon: .endTask) {
                    if let selectedProcess { ProcessSampler.terminate(selectedProcess.id, force: false) }
                }
                .disabled(selectedProcess == nil)
            }

            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        columnHeaders
                        Rectangle().fill(DS.Palette.stroke).frame(height: 1)
                        rows(sections, context)
                    }
                    .frame(width: max(geometry.size.width, minimumWidth), height: geometry.size.height)
                }
            }
        }
    }

    // MARK: Rows

    private func rows(_ sections: [UserSection], _ context: ProcessContext) -> some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(sections.indices, id: \.self) { index in
                    Section {
                        ForEach(sections[index].groups) { userRows($0, context) }
                    } header: {
                        ListSectionTitle(title: sections[index].title)
                    }
                }
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.bottom, DS.Space.l)
            .font(DS.Typeface.body.monospacedDigit())
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private func userRows(_ user: ProcessGroup, _ context: ProcessContext) -> some View {
        let isExpanded = expanded.contains(user.id) || !search.isEmpty
        ProcessLine(group: user, title: "\(user.main.name) (\(user.children.count))", icon: nil, indent: 0,
                    disclosure: isExpanded, columns: Self.columns, context: context,
                    isSelected: selection == user.id, toggle: { toggle(user.id) }, symbol: .user)
            .onTapGesture(count: 2) { toggle(user.id) }
            .onTapGesture { selection = user.id }
            .contextMenu {
                Button(isExpanded ? "Collapse" : "Expand") { toggle(user.id) }
            }

        if isExpanded {
            ForEach(user.children) { process in
                ProcessLine(group: ProcessGroup(main: process, children: []), title: process.name, icon: process.icon,
                            indent: 1, disclosure: nil, columns: Self.columns, context: context,
                            isSelected: selection == process.id, toggle: {})
                    .onTapGesture { selection = process.id }
                    .contextMenu { menu(for: process) }
            }
        }
    }

    @ViewBuilder
    private func menu(for process: ProcessRow) -> some View {
        if process.isApp {
            Button("Switch to") { NSRunningApplication(processIdentifier: process.id)?.activate(options: []) }
        }
        Button("End task") { ProcessSampler.terminate(process.id, force: false) }
        Button("Force quit") { ProcessSampler.terminate(process.id, force: true) }
        Divider()
        if let path = process.path {
            Button("Open file location") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        Button("Search online") { SearchOnline.open(process.name) }
    }

    private func toggle(_ id: pid_t) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    // MARK: Column headers

    private var minimumWidth: CGFloat {
        DS.Size.nameColumnMin + Self.columns.map(\.width).reduce(0, +) + DS.Space.s * 2
    }

    private var columnHeaders: some View {
        HStack(alignment: .bottom, spacing: 0) {
            header(nil, title: "User")
                .padding(.leading, DS.Space.xl)
                .frame(minWidth: DS.Size.nameColumnMin)
            ForEach(Self.columns) { column in
                header(column, title: column.title).frame(width: column.width)
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.s)
    }

    private func header(_ column: ProcessColumn?, title: String) -> some View {
        ColumnHeader(title: title, total: column.flatMap { monitor.columnTotal($0) },
                     alignment: column?.isNumeric == true ? .trailing : .leading,
                     isSorted: sortColumn == column, ascending: ascending) {
            if sortColumn == column {
                ascending.toggle()
            } else {
                sortColumn = column
                ascending = column.map { !$0.isNumeric } ?? true
            }
        }
    }

    // MARK: Data

    private func sections(_ context: ProcessContext) -> [UserSection] {
        let directory = UserDirectory.shared
        let console = UserDirectory.consoleUID()
        var people: [ProcessGroup] = []
        var system: [ProcessGroup] = []

        for (uid, processes) in Dictionary(grouping: monitor.processes, by: \.uid) {
            let account = directory.account(uid)
            let nameMatches = search.isEmpty || account.name.localizedCaseInsensitiveContains(search)
                || account.fullName.localizedCaseInsensitiveContains(search)
            let shown = nameMatches ? processes : processes.filter {
                $0.name.localizedCaseInsensitiveContains(search) || "\($0.id)" == search
            }
            guard !shown.isEmpty else { continue }

            var main = ProcessRow(id: Self.rowID(uid), name: account.title, path: nil, isApp: false, icon: nil,
                                  cpu: -1, memory: 0, threads: nil)
            main.user = account.name
            main.uid = uid
            let children = ProcessGroup.sorted(shown.map { ProcessGroup(main: $0, children: []) }, by: sortColumn,
                                               ascending: ascending, context: context).map(\.main)
            var user = ProcessGroup(main: main, children: children)
            if account.isPerson {
                user.statusOverride = uid == console ? "Active" : "Disconnected"
                people.append(user)
            } else {
                system.append(user)
            }
        }

        let sort = { (groups: [ProcessGroup]) in
            ProcessGroup.sorted(groups, by: sortColumn, ascending: ascending, context: context)
        }
        var sections = [UserSection(title: "Users (\(people.count))", groups: sort(people))]
        if !system.isEmpty {
            sections.append(UserSection(title: "System accounts (\(system.count))", groups: sort(system)))
        }
        return sections
    }

    /// Row IDs share a namespace with PIDs (selection, expansion, `id`), so users get negative ones.
    private static func rowID(_ uid: uid_t) -> pid_t {
        Int32.min + Int32(truncatingIfNeeded: uid & 0x7fff_ffff)
    }
}

/// Account names from the user database, looked up once per UID.
final class UserDirectory {
    struct Account {
        var name: String
        var fullName: String
        /// A person's account rather than root or a `_` system daemon account.
        var isPerson: Bool

        var title: String { isPerson && !fullName.isEmpty ? fullName : name }
    }

    @MainActor static let shared = UserDirectory()

    private var accounts: [uid_t: Account] = [:]

    func account(_ uid: uid_t) -> Account {
        if let account = accounts[uid] { return account }
        var account = Account(name: "\(uid)", fullName: "", isPerson: false)
        if let entry = getpwuid(uid) {
            account.name = String(cString: entry.pointee.pw_name)
            account.fullName = String(cString: entry.pointee.pw_gecos)
        }
        // Regular accounts start at 501; "nobody" is -2.
        account.isPerson = uid >= 500 && uid < 0x7fff_ffff && !account.name.hasPrefix("_")
        accounts[uid] = account
        return account
    }

    /// The user at the login window's console, the one Windows would call "Active".
    static func consoleUID() -> uid_t? {
        var uid: uid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &uid, nil) != nil else { return nil }
        return uid
    }
}

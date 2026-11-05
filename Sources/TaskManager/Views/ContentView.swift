import SwiftUI

/// Window layout modelled on Windows 11 Task Manager:
/// a title bar with the app name and a search box, a collapsible navigation rail on the
/// left, and the selected page on a rounded card.
struct ContentView: View {
    enum Page: String, CaseIterable, Identifiable {
        case processes = "Processes"
        case performance = "Performance"
        case startup = "Startup apps"

        var id: Self { self }

        var icon: FluentIcon {
            switch self {
            case .processes: .processes
            case .performance: .performance
            case .startup: .startup
            }
        }
    }

    @AppStorage("selectedPage") private var page: Page = .performance
    @AppStorage("navigationCollapsed") private var collapsed = false
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(search: $search)

            HStack(spacing: 0) {
                NavigationRail(page: $page, collapsed: $collapsed)

                Group {
                    switch page {
                    case .processes: ProcessesView(search: search)
                    case .performance: PerformanceView()
                    case .startup: StartupView(search: search)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.Palette.cardBackground)
                .clipShape(TopLeadingRoundedRectangle(radius: DS.Radius.card, closed: true))
                .overlay(TopLeadingRoundedRectangle(radius: DS.Radius.card, closed: false).stroke(DS.Palette.stroke))
            }
        }
        .background(DS.Palette.windowBackground)
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// Replaces the system title bar (the window uses a hidden title bar): leaves room for
/// the traffic-light buttons, shows the app name, and hosts the search box.
private struct TitleBar: View {
    @Binding var search: String

    var body: some View {
        ZStack {
            HStack(spacing: DS.Space.s) {
                Spacer().frame(width: 72) // traffic lights
                Fluent(.performance, filled: true, size: DS.Size.icon)
                    .foregroundStyle(DS.Palette.cpu)
                Text("Task Manager").font(DS.Typeface.caption)
                Spacer()
            }
            SearchField(prompt: "Type a name or PID to search", text: $search)
                .frame(width: 360)
        }
        .padding(.horizontal, DS.Space.m)
        .frame(height: DS.Size.titleBar)
        .background(WindowDragArea())
    }
}

/// Makes the whole custom title bar drag the window (the system one is only 28 pt tall)
/// and zoom it on double-click.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }

        // Don't start with the cursor in the search box: Windows doesn't, and stray typing would filter the list.
        override func viewDidMoveToWindow() {
            DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(nil) }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct NavigationRail: View {
    @Binding var page: ContentView.Page
    @Binding var collapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            NavigationButton(icon: .menu, title: nil, isSelected: false, collapsed: collapsed,
                             help: collapsed ? "Expand navigation" : "Collapse navigation") {
                withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() }
            }
            .padding(.bottom, DS.Space.s)

            ForEach(ContentView.Page.allCases) { item in
                NavigationButton(icon: item.icon, title: item.rawValue, isSelected: item == page,
                                 collapsed: collapsed, help: item.rawValue) {
                    page = item
                }
            }
            Spacer()
        }
        .padding(.horizontal, DS.Space.xs + 2)
        .padding(.bottom, DS.Space.s)
        .frame(width: collapsed ? DS.Size.navCollapsed : DS.Size.navExpanded, alignment: .leading)
    }
}

/// A navigation row: Fluent icon (filled when selected), label, gray highlight and
/// a short accent bar on the left when selected.
private struct NavigationButton: View {
    var icon: FluentIcon
    var title: String?
    var isSelected: Bool
    var collapsed: Bool
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.m + 2) {
                Fluent(icon, filled: isSelected, size: DS.Size.navIcon)
                    .frame(width: 20)
                if let title, !collapsed {
                    Text(title)
                        .font(DS.Typeface.body)
                        .lineLimit(1)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.m - 2)
            .frame(height: DS.Size.navRow)
            .rowHighlight(isSelected: isSelected)
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule().fill(Color.accentColor).frame(width: 3, height: 16)
                }
            }
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Rectangle with only the top-leading corner rounded (UnevenRoundedRectangle needs macOS 14).
/// `closed: false` gives just the left and top edges, for drawing the card's border.
private struct TopLeadingRoundedRectangle: Shape {
    var radius: CGFloat
    var closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY + 1))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX + 1, y: rect.minY))
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX + 1, y: rect.maxY + 1))
            path.closeSubpath()
        }
        return path
    }
}

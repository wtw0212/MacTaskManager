import AppKit
import SwiftUI

/// The app's design system, modelled on Windows 11 (Fluent) Task Manager.
/// Every view takes its fonts, spacing, radii, sizes and colors from here, so all pages match.
enum DS {
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        /// Buttons, rows, fields, tiles.
        static let control: CGFloat = 4
        /// The page card.
        static let card: CGFloat = 8
    }

    enum Size {
        static let titleBar: CGFloat = 44
        static let pageHeader: CGFloat = 52
        static let navRow: CGFloat = 36
        static let navExpanded: CGFloat = 220
        static let navCollapsed: CGFloat = 52
        static let listRow: CGFloat = 28
        static let icon: CGFloat = 16
        static let navIcon: CGFloat = 18
        static let valueColumn: CGFloat = 96
        static let tileGraph = CGSize(width: 72, height: 48)
        static let resourceList: CGFloat = 248
    }

    enum Typeface {
        static let pageTitle = Font.system(size: 20, weight: .semibold)
        static let resourceTitle = Font.system(size: 28, weight: .regular)
        static let resourceSubtitle = Font.system(size: 14)
        static let body = Font.system(size: 13)
        static let bodyStrong = Font.system(size: 13, weight: .semibold)
        static let caption = Font.system(size: 11)
        static let statValue = Font.system(size: 20).monospacedDigit()
        static let tileTitle = Font.system(size: 14)
        static let columnTotal = Font.system(size: 15).monospacedDigit()
    }

    enum Palette {
        static let windowBackground = dynamic(light: 0xF3F3F3, dark: 0x202020)
        static let cardBackground = dynamic(light: 0xFBFBFB, dark: 0x272727)
        static let stroke = dynamic(light: 0xE3E3E3, dark: 0x383838)
        static let hover = Color.primary.opacity(0.04)
        static let selected = Color.primary.opacity(0.07)
        static let fieldBackground = dynamic(light: 0xFFFFFF, dark: 0x2D2D2D)

        // Resource colors, as in Windows Task Manager.
        static let cpu = Color(red: 0.07, green: 0.49, blue: 0.73)
        static let memory = Color(red: 0.55, green: 0.07, blue: 0.68)
        static let disk = Color(red: 0.30, green: 0.65, blue: 0.05)
        static let network = Color(red: 0.65, green: 0.31, blue: 0.0)
        static let gpu = Color(red: 0.0, green: 0.52, blue: 0.62)

        /// Heat shading for process value cells: light cyan for idle, deeper teal for busy.
        static func heat(_ level: Double) -> Color {
            let level = min(max(level, 0), 1)
            return Color(nsColor: NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let alpha = dark ? 0.16 + 0.45 * level : 0.12 + 0.50 * level
                return NSColor(srgbRed: 0.0, green: dark ? 0.55 : 0.67, blue: dark ? 0.70 : 0.80, alpha: alpha)
            })
        }

        private static func dynamic(light: Int, dark: Int) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                               green: CGFloat((hex >> 8) & 0xff) / 255,
                               blue: CGFloat(hex & 0xff) / 255,
                               alpha: 1)
            })
        }
    }
}

// MARK: - Page chrome

/// Top bar of every page: title on the left, command buttons on the right.
struct PageHeader<Actions: View>: View {
    var title: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.xs) {
                Text(title).font(DS.Typeface.pageTitle)
                Spacer(minLength: DS.Space.l)
                actions
            }
            .padding(.horizontal, DS.Space.xl)
            .frame(height: DS.Size.pageHeader)
            Rectangle().fill(DS.Palette.stroke).frame(height: 1)
        }
    }
}

/// Flat command-bar button with a Fluent icon, like "Run new task" / "End task" in Windows.
struct CommandButton: View {
    var title: String
    var icon: FluentIcon
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s) {
                Fluent(icon, size: DS.Size.icon)
                Text(title).font(DS.Typeface.body)
            }
            .padding(.horizontal, DS.Space.m)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(hovering && isEnabled ? DS.Palette.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
    }
}

/// Rounded search box with a Fluent search icon.
struct SearchField: View {
    var prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Fluent(.search, size: 14).foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(DS.Typeface.body)
            if !text.isEmpty {
                Button { text = "" } label: { Fluent(.dismiss, size: 12).foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DS.Space.m)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Palette.fieldBackground))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).stroke(DS.Palette.stroke))
    }
}

// MARK: - Lists

/// Hover and selection background shared by every list row and tile.
struct RowHighlight: ViewModifier {
    var isSelected: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control)
                    .fill(isSelected ? DS.Palette.selected : hovering ? DS.Palette.hover : .clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

extension View {
    func rowHighlight(isSelected: Bool) -> some View {
        modifier(RowHighlight(isSelected: isSelected))
    }
}

/// Clickable column header: optional big total above a small label, with a sort chevron.
struct ColumnHeader: View {
    var title: String
    var total: String? = nil
    var alignment: HorizontalAlignment = .leading
    var isSorted: Bool
    var ascending: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: alignment, spacing: DS.Space.xxs) {
                if let total {
                    Text(total).font(DS.Typeface.columnTotal).lineLimit(1)
                }
                HStack(spacing: DS.Space.xs) {
                    Text(title).lineLimit(1)
                    Fluent(.chevronRight, size: 8)
                        .rotationEffect(.degrees(ascending ? -90 : 90))
                        .opacity(isSorted ? 1 : 0)
                }
                .font(DS.Typeface.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .bottom))
            .padding(.horizontal, DS.Space.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Section title inside a list, e.g. "Apps (6)".
struct ListSectionTitle: View {
    var title: String

    var body: some View {
        Text(title)
            .font(DS.Typeface.bodyStrong)
            .padding(.horizontal, DS.Space.xl)
            .padding(.top, DS.Space.m)
            .padding(.bottom, DS.Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.cardBackground)
    }
}

// MARK: - Resource panels

/// "CPU" big title on the left, device name on the right.
struct ResourceHeader: View {
    var title: String
    var subtitle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.l) {
            Text(title).font(DS.Typeface.resourceTitle).lineLimit(1)
            Spacer(minLength: DS.Space.l)
            Text(subtitle)
                .font(DS.Typeface.resourceSubtitle)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// Small caption row with text at both ends, used above and below graphs.
struct CaptionRow: View {
    var leading: String
    var trailing: String

    var body: some View {
        HStack {
            Text(leading)
            Spacer(minLength: DS.Space.s)
            Text(trailing).monospacedDigit()
        }
        .font(DS.Typeface.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// A graph with Windows' captions: title and top value above, "60 seconds" and "0" below.
struct LabeledGraph: View {
    var title: String
    var values: [Double]
    var color: Color
    var secondary: [Double]? = nil
    var maxValue: Double = 1
    var topLabel = "100%"

    var body: some View {
        VStack(spacing: DS.Space.xs) {
            CaptionRow(leading: title, trailing: topLabel)
            UsageGraph(values: values, color: color, secondary: secondary, maxValue: maxValue)
            CaptionRow(leading: "\(PerformanceMonitor.historyLength) seconds", trailing: "0")
        }
    }
}

/// Label above a large value, as in the stats area under Windows' graphs.
/// Values stay on one line and shrink to fit rather than wrap.
struct Stat: View {
    var label: String
    var value: String
    /// Shows a solid or dashed legend line in the series color (for two-series graphs).
    var legend: Color? = nil
    var dashed = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            if let legend {
                Rectangle()
                    .stroke(legend, style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 2] : []))
                    .frame(width: 2, height: 36)
            }
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(label)
                    .font(DS.Typeface.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(DS.Typeface.statValue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .fixedSize()
    }
}

/// The right-hand "Label:  value" table in the stats area.
struct InfoTable: View {
    var rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: DS.Space.xl, verticalSpacing: DS.Space.xs) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0).foregroundStyle(.secondary)
                    Text(row.1).monospacedDigit().minimumScaleFactor(0.7)
                }
                .lineLimit(1)
            }
        }
        .font(DS.Typeface.body)
    }
}

/// Stats area under a graph: a grid of `Stat`s on the left, an `InfoTable` on the right.
struct StatsArea<Stats: View>: View {
    var info: [(String, String)]
    @ViewBuilder var stats: Stats

    var body: some View {
        // Info table beside the stats when there's room, below them when there isn't,
        // so labels and values never wrap or get cut off.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: DS.Space.xl * 2) {
                statsGrid
                InfoTable(rows: info).fixedSize()
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: DS.Space.l) {
                statsGrid
                InfoTable(rows: info).fixedSize()
            }
        }
    }

    private var statsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: DS.Space.xl, verticalSpacing: DS.Space.m) {
            stats
        }
        .fixedSize()
    }
}

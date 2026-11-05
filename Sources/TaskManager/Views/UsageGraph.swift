import SwiftUI

/// A Task Manager style graph: grid, filled area and line, newest value on the right.
/// An optional second series is drawn as a dashed line (e.g. write vs read, send vs receive).
struct UsageGraph: View {
    var values: [Double]
    var color: Color
    var secondary: [Double]? = nil
    var maxValue: Double = 1
    var capacity = PerformanceMonitor.historyLength
    var showsGrid = true

    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            context.fill(Path(bounds), with: .color(color.opacity(0.03)))

            if showsGrid {
                var grid = Path()
                for i in 1..<10 {
                    let x = size.width * CGFloat(i) / 10
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                    let y = size.height * CGFloat(i) / 10
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(color.opacity(0.15)), lineWidth: 0.5)
            }

            if let line = path(for: values, in: size) {
                var area = line.path
                area.addLine(to: CGPoint(x: line.last.x, y: size.height))
                area.addLine(to: CGPoint(x: line.first.x, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(color.opacity(0.2)))
                context.stroke(line.path, with: .color(color), lineWidth: 1.2)
            }
            if let secondary, let line = path(for: secondary, in: size) {
                context.stroke(line.path, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }

            context.stroke(Path(bounds.insetBy(dx: 0.5, dy: 0.5)), with: .color(color.opacity(0.7)), lineWidth: 1)
        }
    }

    private func path(for series: [Double], in size: CGSize) -> (path: Path, first: CGPoint, last: CGPoint)? {
        let samples = Array(series.suffix(capacity))
        guard samples.count > 1, maxValue > 0 else { return nil }
        let step = size.width / CGFloat(capacity - 1)
        let offset = capacity - samples.count
        func point(_ i: Int) -> CGPoint {
            let value = CGFloat(min(max(samples[i] / maxValue, 0), 1))
            return CGPoint(x: CGFloat(offset + i) * step, y: size.height * (1 - value))
        }
        var path = Path()
        path.move(to: point(0))
        for i in 1..<samples.count { path.addLine(to: point(i)) }
        return (path, point(0), point(samples.count - 1))
    }
}

/// Graph with captions around it: title and top value above, "60 seconds" and "0" below.
struct LabeledGraph: View {
    var title: String
    var values: [Double]
    var color: Color
    var secondary: [Double]? = nil
    var maxValue: Double = 1
    var topLabel = "100%"

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(topLabel)
            }
            UsageGraph(values: values, color: color, secondary: secondary, maxValue: maxValue)
            HStack {
                Text("\(PerformanceMonitor.historyLength) seconds")
                Spacer()
                Text("0")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// One label-over-value pair in the stats area under a graph.
struct Stat: View {
    var label: String
    var value: String
    var large = false
    var dashed = false
    var color: Color? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if let color {
                Rectangle()
                    .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 2] : []))
                    .frame(width: 2, height: 30)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(large ? .title2 : .body)
                    .monospacedDigit()
            }
            .fixedSize() // never wrap a label or a value like "168 KB/s"
        }
    }
}

/// The header line of a detail panel: big title on the left, device name on the right.
struct DetailHeader: View {
    var title: String
    var subtitle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.largeTitle)
            Spacer()
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Right-hand "Label:  value" list in a stats area.
struct InfoList: View {
    var rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0).foregroundStyle(.secondary)
                    Text(row.1).monospacedDigit()
                }
            }
        }
        .font(.callout)
    }
}

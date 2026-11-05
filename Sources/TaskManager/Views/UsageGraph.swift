import SwiftUI

/// A Task Manager style graph: grid, filled area and line, newest value on the right.
struct UsageGraph: View {
    var values: [Double]
    var color: Color
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

            let samples = Array(values.suffix(capacity))
            if samples.count > 1 {
                let step = size.width / CGFloat(capacity - 1)
                let offset = capacity - samples.count
                func point(_ i: Int) -> CGPoint {
                    let value = CGFloat(min(max(samples[i], 0), 1))
                    return CGPoint(x: CGFloat(offset + i) * step, y: size.height * (1 - value))
                }

                var line = Path()
                line.move(to: point(0))
                for i in 1..<samples.count { line.addLine(to: point(i)) }

                var area = line
                area.addLine(to: CGPoint(x: point(samples.count - 1).x, y: size.height))
                area.addLine(to: CGPoint(x: point(0).x, y: size.height))
                area.closeSubpath()

                context.fill(area, with: .color(color.opacity(0.2)))
                context.stroke(line, with: .color(color), lineWidth: 1.2)
            }

            context.stroke(Path(bounds.insetBy(dx: 0.5, dy: 0.5)), with: .color(color.opacity(0.7)), lineWidth: 1)
        }
    }
}

/// Graph with the "% Utilization / 100% / 60 seconds / 0" captions around it.
struct LabeledGraph: View {
    var title: String
    var values: [Double]
    var color: Color

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("100%")
            }
            UsageGraph(values: values, color: color)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(large ? .title2 : .body)
                .monospacedDigit()
        }
    }
}

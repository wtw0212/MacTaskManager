import SwiftUI

/// A Task Manager style graph: grid, filled area and line, newest value on the right.
/// An optional second series is drawn as a dashed line (write vs read, send vs receive).
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

            if showsGrid {
                var grid = Path()
                for i in 1..<10 {
                    let x = (size.width * CGFloat(i) / 10).rounded() + 0.5
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                }
                for i in 1..<10 {
                    let y = (size.height * CGFloat(i) / 10).rounded() + 0.5
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(color.opacity(0.12)), lineWidth: 1)
            }

            if let line = path(for: values, in: size) {
                var area = line.path
                area.addLine(to: CGPoint(x: line.last.x, y: size.height))
                area.addLine(to: CGPoint(x: line.first.x, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(color.opacity(0.15)))
                context.stroke(line.path, with: .color(color), lineWidth: 1)
            }
            if let secondary, let line = path(for: secondary, in: size) {
                context.stroke(line.path, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }

            context.stroke(Path(bounds.insetBy(dx: 0.5, dy: 0.5)), with: .color(color), lineWidth: 1)
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

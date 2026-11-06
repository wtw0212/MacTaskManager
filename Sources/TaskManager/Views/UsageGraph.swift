import SwiftUI

/// A Task Manager style graph: grid, filled area and line, newest value on the right.
/// An optional second series is drawn as a dashed line (write vs read, send vs receive).
/// Uses shape layers because each SwiftUI Canvas keeps its own GPU surfaces (over 100 MB
/// across the CPU core grid), while shape layers cost this process little more than their paths.
struct UsageGraph: NSViewRepresentable {
    var values: [Double]
    var color: Color
    var secondary: [Double]? = nil
    var maxValue: Double = 1
    var capacity = PerformanceMonitor.historyLength
    var showsGrid = true

    func makeNSView(context: Context) -> GraphView { GraphView() }

    func updateNSView(_ view: GraphView, context: Context) {
        view.graph = self
    }

    final class GraphView: NSView {
        var graph: UsageGraph? { didSet { redraw() } }

        private let grid = CAShapeLayer()
        private let area = CAShapeLayer()
        private let line = CAShapeLayer()
        private let dashed = CAShapeLayer()
        private let border = CAShapeLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for shape in [grid, area, line, dashed, border] {
                shape.fillColor = nil
                shape.lineWidth = 1
                layer?.addSublayer(shape)
            }
            dashed.lineDashPattern = [4, 3]
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        // Clicks and right-clicks belong to the SwiftUI views around the graph.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            redraw()
        }

        private func redraw() {
            guard let graph, bounds.width > 0, bounds.height > 0 else { return }
            let size = bounds.size
            let color = NSColor(graph.color)
            // Paths are worked out from the top left; layers here count from the bottom left.
            let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for shape in [grid, area, line, dashed, border] { shape.frame = bounds }
            grid.strokeColor = color.withAlphaComponent(0.12).cgColor
            area.fillColor = color.withAlphaComponent(0.15).cgColor
            for shape in [line, dashed, border] { shape.strokeColor = color.cgColor }

            grid.path = graph.showsGrid ? graph.gridPath(in: size).applying(flip).cgPath : nil
            border.path = Path(bounds.insetBy(dx: 0.5, dy: 0.5)).cgPath
            if let series = graph.path(for: graph.values, in: size) {
                var fill = series.path
                fill.addLine(to: CGPoint(x: series.last.x, y: size.height))
                fill.addLine(to: CGPoint(x: series.first.x, y: size.height))
                fill.closeSubpath()
                area.path = fill.applying(flip).cgPath
                line.path = series.path.applying(flip).cgPath
            } else {
                area.path = nil
                line.path = nil
            }
            dashed.path = graph.secondary.flatMap { graph.path(for: $0, in: size) }?.path.applying(flip).cgPath
            CATransaction.commit()
        }
    }

    fileprivate func gridPath(in size: CGSize) -> Path {
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
        return grid
    }

    fileprivate func path(for series: [Double], in size: CGSize) -> (path: Path, first: CGPoint, last: CGPoint)? {
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

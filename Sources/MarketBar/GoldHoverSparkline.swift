import AppKit

/// Compact view for the existing gold price header; draws only real captured segments.
@MainActor
final class GoldHoverSparkline: NSView {
    var trend: GoldTrend? {
        didSet {
            segments = trend?.drawingSegments(buckets: 240) ?? []
            if let low = trend?.low, let high = trend?.high {
                extrema = (low, high)
            } else {
                extrema = nil
            }
            hovered = nil
            needsDisplay = true
        }
    }
    var onHover: ((GoldHistorySample?) -> Void)?
    private var segments: [[GoldHistorySample]] = []
    private var hovered: GoldHistorySample?
    private var extrema: (low: GoldHistorySample, high: GoldHistorySample)?

    func xCoordinate(for sample: GoldHistorySample) -> CGFloat {
        guard let trend, let first = trend.samples.first, let last = trend.samples.last else { return bounds.midX }
        let duration = last.sampledAt.timeIntervalSince(first.sampledAt)
        guard duration > 0 else { return bounds.midX }
        return bounds.minX + 4 + max(1, bounds.width - 8) * CGFloat(
            sample.sampledAt.timeIntervalSince(first.sampledAt) / duration
        )
    }

    func updateHover(at point: NSPoint) {
        guard bounds.contains(point), let trend, let first = trend.samples.first,
              let last = trend.samples.last else {
            setHovered(nil)
            return
        }
        let capturedDuration = last.sampledAt.timeIntervalSince(first.sampledAt)
        if capturedDuration <= 0 {
            setHovered(abs(point.x - bounds.midX) <= 12 ? first : nil)
            return
        }
        let time = first.sampledAt.addingTimeInterval(
            capturedDuration * Double((point.x - bounds.minX - 4) / max(1, bounds.width - 8))
        )
        let candidate = trend.nearest(to: time)
        let tolerance = min(15 * 60, max(90, capturedDuration / bounds.width * 8))
        setHovered(candidate.flatMap { abs($0.sampledAt.timeIntervalSince(time)) <= tolerance ? $0 : nil })
    }

    private func setHovered(_ sample: GoldHistorySample?) {
        guard hovered != sample else { return }
        hovered = sample
        onHover?(sample)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let trend, let (low, high) = extrema else { return }
        let accent = NSColor(calibratedRed: 0.94, green: 0.72, blue: 0.34, alpha: 1)
        let span = max(high.price - low.price, high.price * 0.002, 0.01)
        let bottom = low.price - span * 0.12
        let height = span * 1.24
        func point(_ sample: GoldHistorySample) -> NSPoint {
            NSPoint(
                x: xCoordinate(for: sample),
                y: bounds.minY + 3 + max(1, bounds.height - 6) * CGFloat((sample.price - bottom) / height)
            )
        }
        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: bounds.minX, y: bounds.minY + 3))
        baseline.line(to: NSPoint(x: bounds.maxX, y: bounds.minY + 3))
        NSColor.white.withAlphaComponent(0.12).setStroke()
        baseline.lineWidth = 0.5
        baseline.stroke()
        accent.setStroke()
        for segment in segments {
            let path = NSBezierPath()
            for (index, sample) in segment.enumerated() {
                if index == 0 { path.move(to: point(sample)) }
                else { path.line(to: point(sample)) }
            }
            path.lineWidth = 1.5
            path.stroke()
            if segment.count == 1 {
                let center = point(segment[0])
                accent.setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)).fill()
            }
        }
        if let hovered {
            let center = point(hovered)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)).fill()
        }
    }
}

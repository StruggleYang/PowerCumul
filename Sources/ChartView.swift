//
//  ChartView.swift
//  PowerCumul
//
//  Core Graphics 手绘 24 小时功率折线图。零第三方依赖。
//  输入是最近 24 个小时桶的能量(Wh)，这里近似用 Wh 值 ÷ 小时数 得到该小时平均功率(W)。
//

import AppKit

final class ChartView: NSView {

    /// 每个桶：标签（如 "14时"）+ 数值（W）。外部赋值后触发重绘。
    var data: [(label: String, value: Double)] = [] {
        didSet { needsDisplay = true }
    }

    /// 单位标题，显示在右上角。
    var unitLabel: String = "W" {
        didSet { needsDisplay = true }
    }

    // 配色（在 draw 里按明暗模式取色）。
    private let lineColor = NSColor.systemBlue
    private let fillColor = NSColor.systemBlue.withAlphaComponent(0.15)
    private let axisColor = NSColor.separatorColor
    private let textColor = NSColor.secondaryLabelColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.cornerRadius = 8
        // 不设 layer 背景色：让 popover 的毛玻璃背景透过来，
        // 与面板其他区域保持一致（避免图表出现不透明白色块）。
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 320, height: 110)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        // 不填充背景：保持透明，融入 popover 毛玻璃。

        guard !data.isEmpty else {
            drawEmpty(in: bounds)
            return
        }

        // 绘图区留白：左 28(纵轴标签)、右 8、上 16、下 18(横轴标签)。
        let padLeft: CGFloat = 30
        let padRight: CGFloat = 10
        let padTop: CGFloat = 14
        let padBottom: CGFloat = 20
        let plotRect = NSRect(x: bounds.minX + padLeft,
                              y: bounds.minY + padBottom,
                              width: bounds.width - padLeft - padRight,
                              height: bounds.height - padTop - padBottom)

        let maxValue = max(data.map(\.value).max() ?? 1, 1)   // 避免 max=0 除零
        let niceMax = Self.niceCeil(maxValue)

        drawGridAndAxes(plotRect, niceMax: niceMax)
        drawLine(plotRect, niceMax: niceMax)
        drawXLabels(plotRect)
    }

    // MARK: - 子绘制

    private func drawEmpty(in rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: textColor,
        ]
        let text = "等待数据…" as NSString
        let size = text.size(withAttributes: attrs)
        let origin = NSPoint(x: rect.midX - size.width / 2,
                             y: rect.midY - size.height / 2)
        text.draw(at: origin, withAttributes: attrs)
    }

    private func drawGridAndAxes(_ r: NSRect, niceMax: Double) {
        axisColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        // 纵轴。
        path.move(to: NSPoint(x: r.minX, y: r.minY))
        path.line(to: NSPoint(x: r.minX, y: r.maxY))
        // 横轴。
        path.move(to: NSPoint(x: r.minX, y: r.minY))
        path.line(to: NSPoint(x: r.maxX, y: r.minY))
        path.stroke()

        // 3 条水平刻度 + 纵轴标签。
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: textColor,
        ]
        for i in 0...3 {
            let y = r.minY + r.height * CGFloat(i) / 3
            let value = niceMax * Double(i) / 3
            NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
            let grid = NSBezierPath()
            grid.lineWidth = 0.5
            grid.setLineDash([2, 2], count: 2, phase: 0)
            grid.move(to: NSPoint(x: r.minX, y: y))
            grid.line(to: NSPoint(x: r.maxX, y: y))
            grid.stroke()

            let label = "\(Int(value))" as NSString
            let size = label.size(withAttributes: attrs)
            let origin = NSPoint(x: r.minX - size.width - 4,
                                 y: y - size.height / 2)
            label.draw(at: origin, withAttributes: attrs)
        }
    }

    private func drawLine(_ r: NSRect, niceMax: Double) {
        guard data.count > 1 else {
            // 只有一个点：画一个圆点。
            if let v = data.first {
                let x = r.midX
                let y = r.minY + r.height * CGFloat(v.value / niceMax)
                lineColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: x - 2, y: y - 2, width: 4, height: 4)).fill()
            }
            return
        }

        let count = data.count
        let stepX = r.width / CGFloat(count - 1)

        // 填充区域。
        let fill = NSBezierPath()
        fill.move(to: NSPoint(x: r.minX, y: r.minY))
        for (i, item) in data.enumerated() {
            let x = r.minX + CGFloat(i) * stepX
            let y = r.minY + r.height * CGFloat(item.value / niceMax)
            fill.line(to: NSPoint(x: x, y: y))
        }
        fill.line(to: NSPoint(x: r.minX + CGFloat(count - 1) * stepX, y: r.minY))
        fill.close()
        fillColor.setFill()
        fill.fill()

        // 折线。
        let line = NSBezierPath()
        line.lineWidth = 1.8
        line.lineJoinStyle = .round
        for (i, item) in data.enumerated() {
            let x = r.minX + CGFloat(i) * stepX
            let y = r.minY + r.height * CGFloat(item.value / niceMax)
            if i == 0 { line.move(to: NSPoint(x: x, y: y)) }
            else { line.line(to: NSPoint(x: x, y: y)) }
        }
        lineColor.setStroke()
        line.stroke()

        // 末端圆点（当前值）。
        if let last = data.last {
            let x = r.minX + CGFloat(count - 1) * stepX
            let y = r.minY + r.height * CGFloat(last.value / niceMax)
            lineColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5)).fill()
        }
    }

    private func drawXLabels(_ r: NSRect) {
        guard data.count > 1 else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8),
            .foregroundColor: textColor,
        ]
        // 只标首、中、尾，避免拥挤。
        let indices: [Int] = [0, data.count / 2, data.count - 1]
        let stepX = r.width / CGFloat(data.count - 1)
        for i in indices where i < data.count {
            let x = r.minX + CGFloat(i) * stepX
            let label = data[i].label as NSString
            let size = label.size(withAttributes: attrs)
            let origin = NSPoint(x: x - size.width / 2, y: r.minY - size.height - 4)
            label.draw(at: origin, withAttributes: attrs)
        }
    }

    // MARK: - 工具

    /// 把一个最大值向上取整到"好看"的整数（1/2/5×10^n），用作纵轴上限。
    private static func niceCeil(_ v: Double) -> Double {
        guard v > 0 else { return 1 }
        let exp = floor(log10(v))
        let base = pow(10, exp)
        let norm = v / base
        let nice: Double
        switch norm {
        case ..<1.5: nice = 1.5
        case ..<2:   nice = 2
        case ..<3:   nice = 3
        case ..<5:   nice = 5
        case ..<7:   nice = 7
        default:     nice = 10
        }
        return nice * base
    }
}

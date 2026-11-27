import SwiftUI

/// Draggable fan curve. X: average core temperature, Y: fan level.
/// Drag a point to move it, double-click empty space to add one, double-click a point to remove it.
struct CurveEditor: View {
    @Binding var points: [CurvePoint]
    /// Temperature the fans follow now (smoothed); drawn as the red dot on the curve.
    var currentTemp: Double?
    /// Real core temperature; a faint line when it is away from `currentTemp`.
    var rawTemp: Double?
    var failsafeTemp: Double = 90
    var compact = false

    @State private var dragIndex: Int?
    @State private var hoverIndex: Int?

    private var inset: EdgeInsets {
        compact ? EdgeInsets(top: 8, leading: 36, bottom: 16, trailing: 8)
                : EdgeInsets(top: 12, leading: 38, bottom: 24, trailing: 12)
    }
    private let range = Curve.tempRange

    var body: some View {
        GeometryReader { geo in
            let plot = CGRect(x: inset.leading, y: inset.top,
                              width: geo.size.width - inset.leading - inset.trailing,
                              height: geo.size.height - inset.top - inset.bottom)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in draw(ctx, plot) }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { loc in addPoint(at: loc, plot) }

                ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                    // Gestures and hover go BEFORE .position: after it the view fills the whole editor.
                    handle(i, p)
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .named("curve"))
                                .onChanged { move(i, to: $0.location, plot) }
                                .onEnded { _ in dragIndex = nil }
                        )
                        .onTapGesture(count: 2) { removePoint(i) }
                        .onHover { hoverIndex = $0 ? i : (hoverIndex == i ? nil : hoverIndex) }
                        .position(position(p, plot))
                }

                if let i = dragIndex ?? hoverIndex, i < points.count {
                    let p = points[i]
                    Text("\(Int(p.temp))° → \(Int(p.pct))%")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                        .position(x: position(p, plot).x, y: max(position(p, plot).y - 22, 10))
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "curve")
        }
        .accessibilityLabel(L("a11y.curve"))
        // Temperature always runs cold → hot left to right, also in Arabic and Urdu.
        .environment(\.layoutDirection, .leftToRight)
    }

    // MARK: geometry

    private func x(_ t: Double, _ r: CGRect) -> CGFloat { r.minX + CGFloat((t - range.lowerBound) / (range.upperBound - range.lowerBound)) * r.width }
    private func y(_ f: Double, _ r: CGRect) -> CGFloat { r.maxY - CGFloat(f / 100) * r.height }
    private func position(_ p: CurvePoint, _ r: CGRect) -> CGPoint { CGPoint(x: x(p.temp, r), y: y(p.pct, r)) }
    private func temp(atX px: CGFloat, _ r: CGRect) -> Double { range.lowerBound + Double((px - r.minX) / r.width) * (range.upperBound - range.lowerBound) }
    private func pct(atY py: CGFloat, _ r: CGRect) -> Double { Double((r.maxY - py) / r.height) * 100 }

    // MARK: drawing

    private func draw(_ ctx: GraphicsContext, _ r: CGRect) {
        let grid = Color.primary.opacity(0.07)
        let label = Color.secondary
        for t in stride(from: range.lowerBound, through: range.upperBound, by: compact ? 20 : 10) where !compact || t != range.lowerBound {
            var p = Path(); p.move(to: CGPoint(x: x(t, r), y: r.minY)); p.addLine(to: CGPoint(x: x(t, r), y: r.maxY))
            ctx.stroke(p, with: .color(grid), lineWidth: 1)
            ctx.draw(Text("\(Int(t))°").font(.caption2).foregroundColor(label), at: CGPoint(x: x(t, r), y: r.maxY + 5), anchor: .top)
        }
        for f in stride(from: 0.0, through: 100, by: compact ? 50 : 25) {
            var p = Path(); p.move(to: CGPoint(x: r.minX, y: y(f, r))); p.addLine(to: CGPoint(x: r.maxX, y: y(f, r)))
            ctx.stroke(p, with: .color(grid), lineWidth: 1)
            ctx.draw(Text("\(Int(f))%").font(.caption2).foregroundColor(label), at: CGPoint(x: r.minX - 6, y: y(f, r)), anchor: .trailing)
        }

        // fail-safe zone
        let fx = x(min(failsafeTemp, range.upperBound), r)
        ctx.fill(Path(CGRect(x: fx, y: r.minY, width: r.maxX - fx, height: r.height)), with: .color(.red.opacity(0.06)))
        if !compact {
            ctx.draw(Text(L("curve.failsafe")).font(.caption2.weight(.medium)).foregroundColor(.red.opacity(0.7)),
                     at: CGPoint(x: fx + 5, y: r.maxY - 4), anchor: .bottomLeading)
        }

        guard let first = points.first, let last = points.last else { return }
        var line = Path()
        line.move(to: CGPoint(x: r.minX, y: y(first.pct, r)))
        for p in points { line.addLine(to: position(p, r)) }
        line.addLine(to: CGPoint(x: r.maxX, y: y(last.pct, r)))
        var area = line
        area.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        area.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        area.closeSubpath()
        ctx.fill(area, with: .linearGradient(Gradient(colors: [.accentColor.opacity(0.22), .accentColor.opacity(0.03)]),
                                             startPoint: CGPoint(x: 0, y: r.minY), endPoint: CGPoint(x: 0, y: r.maxY)))
        ctx.stroke(line, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

        if let raw = rawTemp, let t = currentTemp, abs(raw - t) >= 1 {
            let rt = min(max(raw, range.lowerBound), range.upperBound)
            var v = Path(); v.move(to: CGPoint(x: x(rt, r), y: r.minY)); v.addLine(to: CGPoint(x: x(rt, r), y: r.maxY))
            ctx.stroke(v, with: .color(.red.opacity(0.22)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
        if let t = currentTemp {
            let ct = min(max(t, range.lowerBound), range.upperBound)
            var v = Path(); v.move(to: CGPoint(x: x(ct, r), y: r.minY)); v.addLine(to: CGPoint(x: x(ct, r), y: r.maxY))
            ctx.stroke(v, with: .color(.red.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            let dot = CGPoint(x: x(ct, r), y: y(Curve.value(points, at: ct), r))
            ctx.fill(Path(ellipseIn: CGRect(x: dot.x - 4, y: dot.y - 4, width: 8, height: 8)), with: .color(.red))
        }
    }

    private func handle(_ i: Int, _ p: CurvePoint) -> some View {
        let active = dragIndex == i || hoverIndex == i
        return Circle()
            .fill(active ? Color.accentColor : Color(nsColor: .windowBackgroundColor))
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2.5))
            .frame(width: active ? (compact ? 13 : 16) : (compact ? 10 : 13), height: active ? (compact ? 13 : 16) : (compact ? 10 : 13))
            .frame(width: compact ? 22 : 28, height: compact ? 22 : 28)  // larger hit area
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.12), value: active)
    }

    // MARK: editing

    private func move(_ i: Int, to loc: CGPoint, _ r: CGRect) {
        guard i < points.count else { return }
        dragIndex = i
        let lo = i > 0 ? points[i - 1].temp + Curve.minGap : range.lowerBound
        let hi = i < points.count - 1 ? points[i + 1].temp - Curve.minGap : range.upperBound
        var p = points
        p[i] = CurvePoint(temp: min(max(temp(atX: loc.x, r).rounded(), lo), hi),
                          pct: min(max(pct(atY: loc.y, r).rounded(), 0), 100))
        // keep the curve rising: drag neighbours along instead of rejecting the move
        for k in stride(from: i + 1, to: p.count, by: 1) { p[k].pct = max(p[k].pct, p[k - 1].pct) }
        for k in stride(from: i - 1, through: 0, by: -1) { p[k].pct = min(p[k].pct, p[k + 1].pct) }
        if p != points { points = p }
    }

    private func addPoint(at loc: CGPoint, _ r: CGRect) {
        guard r.insetBy(dx: -4, dy: -4).contains(loc), points.count < Curve.maxPoints else { return }
        let t = temp(atX: loc.x, r).rounded()
        guard !points.contains(where: { abs($0.temp - t) < Curve.minGap }) else { return }
        points = Curve.normalized(points + [CurvePoint(temp: t, pct: Curve.value(points, at: t).rounded())])
    }

    private func removePoint(_ i: Int) {
        guard points.count > 2, i < points.count else { return }
        var p = points
        p.remove(at: i)
        hoverIndex = nil
        points = p
    }
}

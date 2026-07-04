import SwiftUI
import AppKit
import FanCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var curveTab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            telemetry
            Divider()
            Toggle(isOn: Binding(get: { model.config.enabled },
                                 set: { model.setEnabled($0) })) {
                Text("Active fan control").bold()
            }
            Text("When off, the fan returns to macOS automatic control.")
                .font(.caption).foregroundColor(.secondary)
            responseProfile
            Toggle(isOn: Binding(get: { model.launchAtLogin },
                                 set: { model.setLaunchAtLogin($0) })) {
                Text("Launch at login")
            }
            Divider()
            curves
            if let err = model.lastError {
                Text(err).font(.caption).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button("Reset curves") {
                    var d = FanConfig.defaults()
                    d.enabled = model.config.enabled
                    model.config = d
                    model.save()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var responseProfile: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Response", selection: Binding(
                get: { model.config.profile },
                set: { model.setProfile($0) })) {
                Text("Responsive").tag(ResponseProfile.responsive)
                Text("Calm").tag(ResponseProfile.calm)
            }
            .pickerStyle(.segmented)
            Text(model.config.profile == .calm
                 ? "Calm: long time constant, slow wind-down — brief load dips stay inaudible."
                 : "Responsive: fan tracks load closely so you can hear how hard it's pushed.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "wind")
            Text("GPU Fan").font(.headline)
            Spacer()
            Circle().fill(model.daemonAlive ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(model.daemonAlive ? "daemon" : "no daemon")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    @ViewBuilder private var telemetry: some View {
        if let t = model.telemetry, model.daemonAlive {
            VStack(alignment: .leading, spacing: 3) {
                // Columnar readout mirroring the CLI's `run` output:
                //   gpu%  gpuT°C  dieT°C  ->  target  actual
                Grid(horizontalSpacing: 14, verticalSpacing: 1) {
                    GridRow {
                        statHead("gpu%"); statHead("gpuT°C"); statHead("dieT°C")
                        Text(" ").gridColumnAlignment(.center)
                        statHead(t.forced ? "target" : "mode"); statHead("actual")
                    }
                    GridRow {
                        statNum(String(format: "%.1f", t.gpuPct))
                        statNum(String(format: "%.1f", t.gpuTempC))
                        statNum(String(format: "%.1f", t.dieTempC))
                        Text("→").foregroundColor(.secondary)
                        statNum(t.forced ? String(format: "%.0f", t.targetRPM) : "auto")
                        statNum(String(format: "%.0f", t.fanRPM))
                    }
                }
                Text(t.forced ? "fan forced · driven by \(t.driver)" : "fan on macOS automatic control")
                    .font(.caption2).foregroundColor(.secondary)
            }
        } else {
            Text("Daemon not running.\nInstall with:  sudo fancurvectl install")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statHead(_ s: String) -> some View {
        Text(s).font(.caption).foregroundColor(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func statNum(_ s: String) -> some View {
        Text(s).font(.system(.body, design: .monospaced).weight(.semibold))
            .monospacedDigit()
    }

    private var curves: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Fan curve — target = max of all three. Drag points · double-click to add · right-click to delete.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $curveTab) {
                Text("gpu%").tag(0)
                Text("gpuT°C").tag(1)
                Text("dieT°C").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            let yMin = model.telemetry?.fanMinRPM ?? 1000
            let yMax = model.telemetry?.fanMaxRPM ?? 4900
            let live = model.daemonAlive ? model.telemetry : nil

            switch curveTab {
            case 0:
                CurveGraphView(curve: $model.config.gpuCurve,
                               xDomain: 0...100, yDomain: yMin...yMax,
                               liveX: live?.gpuPct, xUnit: "%", accent: .blue,
                               onCommit: { model.save() })
            case 1:
                CurveGraphView(curve: $model.config.gpuTempCurve,
                               xDomain: 50...120, yDomain: yMin...yMax,
                               liveX: live?.gpuTempC, xUnit: "°C", accent: .orange,
                               onCommit: { model.save() })
            default:
                CurveGraphView(curve: $model.config.dieTempCurve,
                               xDomain: 50...120, yDomain: yMin...yMax,
                               liveX: live?.dieTempC, xUnit: "°C", accent: .red,
                               onCommit: { model.save() })
            }
        }
    }
}

/// Draggable, live fan-curve editor. X is the input (GPU% or °C), Y is RPM.
/// Drag a point to reshape, double-click empty space to add, right-click a
/// point to delete. A dashed line + dot show the current operating point.
struct CurveGraphView: View {
    @Binding var curve: Curve
    let xDomain: ClosedRange<Double>
    let yDomain: ClosedRange<Double>
    let liveX: Double?
    let xUnit: String
    let accent: Color
    let onCommit: () -> Void

    private func px(_ x: Double, _ w: CGFloat) -> CGFloat {
        let span = xDomain.upperBound - xDomain.lowerBound
        return CGFloat((x - xDomain.lowerBound) / span) * w
    }
    private func py(_ rpm: Double, _ h: CGFloat) -> CGFloat {
        let span = yDomain.upperBound - yDomain.lowerBound
        return h - CGFloat((rpm - yDomain.lowerBound) / span) * h
    }
    private func dataX(_ vx: CGFloat, _ w: CGFloat) -> Double {
        let span = xDomain.upperBound - xDomain.lowerBound
        return xDomain.lowerBound + Double(max(0, min(1, vx / w))) * span
    }
    private func dataY(_ vy: CGFloat, _ h: CGFloat) -> Double {
        let span = yDomain.upperBound - yDomain.lowerBound
        return yDomain.lowerBound + Double(max(0, min(1, (h - vy) / h))) * span
    }

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in
                        let grid = Color.secondary.opacity(0.18)
                        for frac in [0.0, 0.25, 0.5, 0.75, 1.0] {
                            let y = size.height * CGFloat(frac)
                            var line = Path()
                            line.move(to: CGPoint(x: 0, y: y))
                            line.addLine(to: CGPoint(x: size.width, y: y))
                            ctx.stroke(line, with: .color(grid), lineWidth: 0.5)
                        }
                        var path = Path()
                        for (i, p) in curve.points.enumerated() {
                            let pt = CGPoint(x: px(p.x, size.width), y: py(p.rpm, size.height))
                            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                        }
                        ctx.stroke(path, with: .color(accent), lineWidth: 2)

                        if let lx = liveX, xDomain.contains(lx) {
                            let X = px(lx, size.width)
                            var v = Path()
                            v.move(to: CGPoint(x: X, y: 0))
                            v.addLine(to: CGPoint(x: X, y: size.height))
                            ctx.stroke(v, with: .color(.secondary.opacity(0.6)),
                                       style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            let r = CGRect(x: X - 4, y: py(curve.rpm(for: lx), size.height) - 4,
                                           width: 8, height: 8)
                            ctx.fill(Path(ellipseIn: r), with: .color(.primary))
                        }
                    }

                    ForEach(curve.points.indices, id: \.self) { i in
                        let pid = curve.points[i].id
                        Circle()
                            .fill(accent)
                            .frame(width: 12, height: 12)
                            .position(x: px(curve.points[i].x, w), y: py(curve.points[i].rpm, h))
                            .gesture(
                                DragGesture(minimumDistance: 1, coordinateSpace: .named("graph"))
                                    .onChanged { value in
                                        let lo = i > 0 ? curve.points[i - 1].x + 0.5 : xDomain.lowerBound
                                        let hi = i < curve.points.count - 1 ? curve.points[i + 1].x - 0.5 : xDomain.upperBound
                                        curve.points[i].x = min(hi, max(lo, dataX(value.location.x, w)))
                                        curve.points[i].rpm = min(yDomain.upperBound, max(yDomain.lowerBound, dataY(value.location.y, h)))
                                    }
                                    .onEnded { _ in onCommit() }
                            )
                            .contextMenu {
                                if curve.points.count > 2 {
                                    Button("Delete point", role: .destructive) {
                                        curve.points.removeAll { $0.id == pid }
                                        onCommit()
                                    }
                                }
                            }
                    }

                    Text("\(Int(yDomain.upperBound))")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                        .position(x: 16, y: 7)
                    Text("\(Int(yDomain.lowerBound))")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                        .position(x: 16, y: h - 7)
                }
                .coordinateSpace(.named("graph"))
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture(count: 2, coordinateSpace: .named("graph"))
                        .onEnded { ev in
                            curve.points.append(Curve.Point(x: dataX(ev.location.x, w),
                                                            rpm: dataY(ev.location.y, h)))
                            curve.points.sort { $0.x < $1.x }
                            onCommit()
                        }
                )
            }
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))

            HStack {
                Text("\(Int(xDomain.lowerBound))\(xUnit)")
                Spacer()
                Text("\(Int(xDomain.upperBound))\(xUnit)")
            }
            .font(.system(size: 9)).foregroundColor(.secondary)
        }
    }
}

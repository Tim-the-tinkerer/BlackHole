import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: HoleModel
    @State private var hovering = false
    @State private var rippleStart: Date?

    var body: some View {
        let caption = statusCaption
        ZStack {
            Color.black
            HoleView(
                linked: !model.peerNames.isEmpty,
                hovering: hovering,
                transferring: model.progress != nil,
                progress: model.progress ?? 0,
                rippleStart: rippleStart
            )
            VStack(spacing: 2) {
                Text(caption.title)
                    .font(.system(size: caption.quiet ? 10.5 : 11.5, weight: caption.quiet ? .regular : .medium))
                    .foregroundStyle(caption.alert ? Theme.warn : Color.white.opacity(caption.quiet ? 0.74 : 0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(height: 14)
                Text(caption.detail)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(caption.alert ? Theme.warn.opacity(0.9) : Color.white.opacity(0.68))
                    .lineLimit(2)
                    .frame(height: 13)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $hovering, perform: handleDrop)
        .onChange(of: model.pulseToken) { _ in rippleStart = Date() }
        .onChange(of: model.banner) { banner in
            if let banner, banner.hasPrefix("Sent") { rippleStart = Date() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption.spoken)
        .accessibilityHint("Drop files to copy them to the other computer.")
    }

    private var statusCaption: Caption {
        let who = NameList.join(model.peerNames)
        if hovering {
            if who.isEmpty {
                return Caption(title: "Waiting", detail: "", alert: true, quiet: false)
            }
            return Caption(title: "Drop into \(who)", detail: "", alert: false, quiet: false)
        }
        if let banner = model.banner {
            return Caption.banner(banner, who: who, alert: model.bannerAlert)
        }
        if !who.isEmpty {
            return Caption(title: who, detail: "Ready", alert: false, quiet: true)
        }
        if let trouble = model.trouble, !trouble.isEmpty {
            return Caption(title: trouble, detail: "", alert: true, quiet: false)
        }
        return Caption(title: "Waiting", detail: "", alert: false, quiet: true)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let found = item as? URL {
                    url = found
                } else if let data = item as? Data, let text = String(data: data, encoding: .utf8) {
                    url = URL(string: text)
                } else if let text = item as? String {
                    url = URL(string: text)
                } else {
                    url = nil
                }
                guard let url else { return }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }
        group.notify(queue: .main) {
            if !urls.isEmpty { model.drop(urls) }
        }
        return true
    }
}

private struct Caption {
    var title: String
    var detail: String
    var alert: Bool
    /// Idle destination name. Drag and messages use the stronger line.
    var quiet: Bool

    var spoken: String {
        detail.isEmpty ? title : "\(title), \(detail)"
    }

    static func banner(_ banner: String, who: String, alert: Bool) -> Caption {
        if banner.hasPrefix("Sending ") {
            return Caption(title: who.isEmpty ? banner : who, detail: who.isEmpty ? "" : banner, alert: false, quiet: !who.isEmpty)
        }
        if banner == "Counting…" {
            return Caption(title: who.isEmpty ? "Counting" : who, detail: who.isEmpty ? "" : "Counting", alert: false, quiet: !who.isEmpty)
        }
        if banner.hasPrefix("Sent to ") {
            return Caption(title: who.isEmpty ? "Sent" : who, detail: sentDetail(banner, who: who), alert: alert, quiet: !who.isEmpty)
        }
        if banner.hasSuffix(" arrived") {
            let name = String(banner.dropLast(" arrived".count))
            return Caption(title: name, detail: "Arrived", alert: false, quiet: false)
        }
        if banner.hasSuffix(" files arrived") {
            let count = String(banner.dropLast(" files arrived".count))
            return Caption(title: "\(count) files", detail: "Arrived", alert: false, quiet: false)
        }
        return Caption(title: banner, detail: "", alert: alert, quiet: false)
    }

    private static func sentDetail(_ banner: String, who: String) -> String {
        var rest = String(banner.dropFirst("Sent to ".count))
        if !who.isEmpty, rest.hasPrefix(who) {
            rest = String(rest.dropFirst(who.count)).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix(".") {
                rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
        }
        if rest.isEmpty { return "Sent" }
        if rest.hasPrefix("—") { return "Sent \(rest)" }
        return "Sent. \(rest)"
    }
}

/// Edge-on hole. The bow above the shadow and the rings below it are the same disk, bent around the hole.
private struct HoleView: View {
    var linked: Bool
    var hovering: Bool
    var transferring: Bool
    var progress: Double
    var rippleStart: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { timeline in
            let divisor = hovering ? 8.0 : (transferring ? 11.0 : 16.0)
            let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate / divisor
            let ripple = rippleAmount(at: timeline.date)
            Canvas { context, size in
                draw(in: &context, size: size, phase: phase, ripple: ripple)
            }
        }
        .allowsHitTesting(false)
    }

    private func rippleAmount(at date: Date) -> Double? {
        guard let rippleStart else { return nil }
        let age = date.timeIntervalSince(rippleStart)
        guard age >= 0, age < 0.85 else { return nil }
        return age / 0.85
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, phase: Double, ripple: Double?) {
        let glow = hovering ? 1.05 : (linked ? 0.92 : 0.72)
        let enlarge = (hovering ? 1.06 : 1.0) * (transferring ? 1.025 : 1.0)
        let breathe = transferring ? 0.045 + 0.07 * progress : 0
        let pull = CGFloat(breathe * (0.75 + 0.25 * sin(phase * .pi * 2)))
        let rim = (hovering ? 1.28 : 1.0) * (transferring ? (0.9 + 0.14 * sin(phase * .pi * 4)) : 1)
        let cx = size.width * 0.5
        let cy = size.height * 0.46
        let shadow = min(size.width * 0.092, size.height * 0.25) * enlarge
        guard shadow > 4 else { return }

        softGlow(in: &context, cx: cx, cy: cy, shadow: shadow, glow: glow)
        equator(in: &context, size: size, cx: cx, cy: cy, shadow: shadow, glow: glow, phase: phase, pull: pull)
        upperBow(in: &context, cx: cx, cy: cy, shadow: shadow, glow: glow, phase: phase, pull: pull)
        lowerRings(in: &context, size: size, cx: cx, cy: cy, shadow: shadow, glow: glow, pull: pull)
        photonRing(in: &context, cx: cx, cy: cy, shadow: shadow, glow: glow, rim: rim)

        let hole = CGRect(x: cx - shadow, y: cy - shadow, width: shadow * 2, height: shadow * 2)
        context.fill(Path(ellipseIn: hole), with: .color(.black))

        context.stroke(
            Path(ellipseIn: hole.insetBy(dx: -0.8, dy: -0.8)),
            with: .color(heat(0).opacity(min(1, 0.98 * rim))),
            style: StrokeStyle(lineWidth: max(1.15, shadow * (hovering ? 0.034 : 0.026)), lineCap: .round)
        )

        if let ripple {
            let radius = shadow * (1.12 + CGFloat(ripple) * 0.8)
            let alpha = pow(1 - ripple, 1.35) * 0.55
            let rect = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(heat(0.04).opacity(alpha)),
                style: StrokeStyle(lineWidth: max(0.8, shadow * 0.03 * (1.15 - ripple)), lineCap: .round)
            )
        }

        vignette(in: &context, size: size, cx: cx, cy: cy, shadow: shadow)
    }

    private func vignette(in context: inout GraphicsContext, size: CGSize, cx: CGFloat, cy: CGFloat, shadow: CGFloat) {
        let reach = max(size.width, size.height) * 0.78
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.34),
                    .init(color: .black.opacity(0.08), location: 0.62),
                    .init(color: .black.opacity(0.34), location: 1),
                ]),
                center: CGPoint(x: cx, y: cy),
                startRadius: shadow * 1.8,
                endRadius: reach
            )
        )
    }

    private func softGlow(in context: inout GraphicsContext, cx: CGFloat, cy: CGFloat, shadow: CGFloat, glow: Double) {
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: shadow * 0.45))
            var hill = hillPath(cx: cx, cy: cy, reach: shadow * 5.6, peak: shadow * 1.7)
            hill.addLine(to: CGPoint(x: cx + shadow * 5.6, y: cy + shadow * 0.15))
            hill.addLine(to: CGPoint(x: cx - shadow * 5.6, y: cy + shadow * 0.15))
            hill.closeSubpath()
            layer.fill(hill, with: .color(heat(0.35).opacity(0.22 * glow)))
            let plate = CGRect(x: cx - shadow * 5.4, y: cy - shadow * 0.07, width: shadow * 10.8, height: shadow * 0.16)
            layer.fill(Path(ellipseIn: plate), with: .color(heat(0.12).opacity(0.55 * glow)))
            let bowl = CGRect(x: cx - shadow * 1.45, y: cy + shadow * 0.25, width: shadow * 2.9, height: shadow * 1.35)
            layer.fill(Path(ellipseIn: bowl), with: .color(heat(0.28).opacity(0.28 * glow)))
        }
    }

    private func equator(in context: inout GraphicsContext, size: CGSize, cx: CGFloat, cy: CGFloat, shadow: CGFloat, glow: Double, phase: Double, pull: CGFloat) {
        let span = size.width * 0.96 * (1 - pull * 0.22)
        let left = cx - span * 0.5
        for i in -3...3 {
            let spread = CGFloat(i) / 3
            let y = cy + spread * shadow * 0.055
            let fade = Double(exp(-pow(spread * 1.4, 2)))
            var line = Path()
            line.move(to: CGPoint(x: left, y: y))
            line.addLine(to: CGPoint(x: left + span, y: y))
            let hot = 0.62 + 0.38 * sin(phase * .pi * 2 + Double(i) * 0.4)
            let alpha = fade * hot * 0.85 * glow
            context.stroke(
                line,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: heat(0.85).opacity(alpha * 0.2), location: 0.06),
                        .init(color: heat(0.05).opacity(alpha), location: 0.38),
                        .init(color: heat(0.2).opacity(alpha * 0.2), location: 0.50),
                        .init(color: heat(0.18).opacity(alpha * 0.82), location: 0.62),
                        .init(color: heat(0.9).opacity(alpha * 0.16), location: 0.92),
                        .init(color: .clear, location: 1),
                    ]),
                    startPoint: CGPoint(x: left, y: y),
                    endPoint: CGPoint(x: left + span, y: y)
                ),
                style: StrokeStyle(lineWidth: max(0.6, shadow * 0.028))
            )
        }
    }

    private func upperBow(in context: inout GraphicsContext, cx: CGFloat, cy: CGFloat, shadow: CGFloat, glow: Double, phase: Double, pull: CGFloat) {
        let count = 22
        for i in 0..<count {
            let t = CGFloat(i) / CGFloat(count - 1)
            let wobble = CGFloat(sin(Double(i) * 2.1 + phase)) * shadow * 0.015
            let inward = 1 - pull * (0.15 + 0.85 * t)
            let reach = (shadow * (1.7 + pow(t, 0.62) * 4.4) + wobble) * inward
            let peak = (shadow * (1.08 + pow(t, 0.9) * 0.62) + wobble) * (1 - pull * 0.28)
            let path = hillPath(cx: cx, cy: cy, reach: reach, peak: peak)
            let travel = 0.84 + 0.16 * sin(phase * .pi * 2 - Double(t) * 7)
            let alpha = (0.95 - Double(t) * 0.62) * travel * glow
            let width = max(0.4, shadow * (0.026 - t * 0.012))
            context.stroke(
                path,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: heat(0.15 + t * 0.7).opacity(alpha * 0.55), location: 0),
                        .init(color: heat(t * 0.2).opacity(alpha), location: 0.36),
                        .init(color: heat(0.08 + t * 0.45).opacity(alpha * 0.85), location: 0.64),
                        .init(color: heat(0.55 + t * 0.4).opacity(alpha * 0.35), location: 1),
                    ]),
                    startPoint: CGPoint(x: cx - reach, y: cy),
                    endPoint: CGPoint(x: cx + reach, y: cy)
                ),
                style: StrokeStyle(lineWidth: width, lineCap: .round)
            )
        }
    }

    private func lowerRings(in context: inout GraphicsContext, size: CGSize, cx: CGFloat, cy: CGFloat, shadow: CGFloat, glow: Double, pull: CGFloat) {
        context.drawLayer { layer in
            let clip = CGRect(x: 0, y: cy + shadow * 0.18, width: size.width, height: size.height)
            layer.clip(to: Path(clip))
            let count = 9
            let ringY = cy + shadow * 0.16
            for i in 0..<count {
                let t = CGFloat(i) / CGFloat(count - 1)
                let radius = shadow * (0.98 + t * 0.62) * (1 - pull * t * 0.35)
                let rect = CGRect(x: cx - radius, y: ringY - radius, width: radius * 2, height: radius * 2)
                let lowest = ringY + radius
                let fadeStart = cy + shadow * 1.2
                let fadeEnd = size.height - 48
                let span = max(12, fadeEnd - fadeStart)
                let approach = min(1, max(0, (lowest - fadeStart) / span))
                let dissolve = pow(1 - Double(approach), 1.2)
                let alpha = (0.95 - Double(t) * 0.5) * glow * dissolve
                layer.stroke(
                    Path(ellipseIn: rect),
                    with: .color(heat(0.06 + t * 0.7).opacity(alpha)),
                    style: StrokeStyle(lineWidth: max(0.6, shadow * (0.03 - t * 0.012)))
                )
            }
        }
    }

    private func photonRing(in context: inout GraphicsContext, cx: CGFloat, cy: CGFloat, shadow: CGFloat, glow: Double, rim: Double) {
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: shadow * 0.045))
            let rect = CGRect(x: cx - shadow * 1.015, y: cy - shadow * 1.015, width: shadow * 2.03, height: shadow * 2.03)
            layer.stroke(Path(ellipseIn: rect), with: .color(heat(0).opacity(min(1, 0.8 * rim))), lineWidth: shadow * 0.055)
        }
    }

    /// Flat at the wings, raised over the hole. A parabola reads as a rainbow; this is the disk.
    private func hillPath(cx: CGFloat, cy: CGFloat, reach: CGFloat, peak: CGFloat) -> Path {
        var path = Path()
        let steps = 30
        for step in 0...steps {
            let u = CGFloat(step) / CGFloat(steps)
            let x = cx + (u - 0.5) * 2 * reach
            let n = (x - cx) / max(reach, 1)
            let y = cy - peak * CGFloat(exp(-Double(n * n) * 2.4))
            let point = CGPoint(x: x, y: y)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    /// 0 is white-hot orange. 1 is deep red.
    private func heat(_ t: CGFloat) -> Color {
        let x = min(1, max(0, t))
        return Color(red: 1, green: 0.58 - x * 0.46, blue: 0.14 - x * 0.12)
    }
}

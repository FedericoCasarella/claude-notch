import SwiftUI
import AppKit

// MARK: - Palette & motion

enum Theme {
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)   // #D97757
    static let open = Animation.spring(response: 0.42, dampingFraction: 0.74)
    static let close = Animation.spring(response: 0.34, dampingFraction: 0.92)

    /// Colour by usage fraction: > 75% used → red, > 50% used → yellow.
    static func tint(_ used: Double?) -> Color {
        guard let u = used else { return .gray }
        switch u {
        case 0.75...: return Color(red: 1.0, green: 0.33, blue: 0.33)
        case 0.5...:  return Color(red: 1.0, green: 0.8, blue: 0.2)
        default:      return Color(red: 0.36, green: 0.89, blue: 0.56)
        }
    }
}

// MARK: - Notch shape (inward flares on top, rounded bottom)

struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let t = topRadius, b = bottomRadius
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Root

struct NotchRootView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var store: UsageStore
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        let open = model.isOpen
        let size = open ? model.openSize : model.closedSize
        let shape = NotchShape(topRadius: open ? 14 : 7, bottomRadius: open ? 30 : 11)

        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                if open {
                    ExpandedView(model: model, store: store)
                        .transition(.blurFade(scale: 0.86).animation(Theme.open.delay(0.06)))
                } else {
                    CollapsedView(model: model, store: store)
                        .transition(.blurFade(scale: 1.1).animation(.easeOut(duration: 0.2)))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(shape.fill(.black))
            .clipShape(shape)
            .overlay(shape.stroke(.white.opacity(open ? 0.06 : 0), lineWidth: 1))
            .shadow(color: .black.opacity(open ? 0.6 : 0), radius: 22, y: 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(open ? Theme.open : Theme.close, value: open)
        .animation(Theme.open, value: settings.showCPU)
        .animation(Theme.open, value: settings.showRAM)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Collapsed

struct CollapsedView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var store: UsageStore
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var system = SystemMonitor.shared

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                ClaudeSpark(size: 13, spinning: store.isLoading)
                CountingText(value: (store.session?.used ?? 0) * 100, format: { "\(Int($0.rounded()))%" })
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.tint(store.session?.used))
                    .animation(.spring(response: 0.8), value: store.session?.used)
            }
            .frame(width: model.sideWidth - NotchModel.edgeInset, alignment: .leading)
            .padding(.leading, NotchModel.edgeInset)

            Spacer(minLength: model.notchSize.width)

            HStack(spacing: 7) {
                if settings.showCPU {
                    MiniRing(value: system.cpu, symbol: "cpu")
                        .transition(.scale.combined(with: .opacity))
                }
                if settings.showRAM {
                    MiniRing(value: system.ram, symbol: "memorychip")
                        .transition(.scale.combined(with: .opacity))
                }
                DualRing(outer: store.session?.used, inner: store.weekly?.used)
                    .frame(width: 18, height: 18)
            }
            .frame(width: model.sideWidth - NotchModel.edgeInset, alignment: .trailing)
            .padding(.trailing, NotchModel.edgeInset + 3)
        }
        .frame(height: model.notchSize.height)
    }
}

/// Outer ring = session, inner ring = week (filled by usage). Pulses when nearly exhausted.
struct DualRing: View {
    let outer: Double?
    let inner: Double?
    @State private var pulse = false

    var body: some View {
        let low = (outer ?? 0) > 0.75 || (inner ?? 0) > 0.75
        ZStack {
            ring(outer, width: 2.6)
            ring(inner, width: 2.6).padding(4.5)
        }
        .shadow(color: low ? Theme.tint(1).opacity(pulse ? 0.9 : 0.1) : .clear, radius: 5)
        .animation(.spring(response: 0.9, dampingFraction: 0.8), value: outer)
        .animation(.spring(response: 0.9, dampingFraction: 0.8), value: inner)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private func ring(_ v: Double?, width: CGFloat) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: width)
            Circle().trim(from: 0, to: v ?? 0)
                .stroke(Theme.tint(v), style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// Small live ring for CPU / RAM in the closed notch.
struct MiniRing: View {
    let value: Double
    let symbol: String

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: 2.4)
            Circle().trim(from: 0, to: value)
                .stroke(Theme.tint(value), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: symbol)
                .font(.system(size: 6.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(width: 16, height: 16)
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: value)
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var store: UsageStore
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: model.notchSize.height)

            if let err = store.error, store.session == nil {
                errorView(err)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    GaugeCard(title: "Sessione 5h", window: store.session, index: 0)
                    GaugeCard(title: "Settimana", window: store.weekly, index: 1)
                    TodayCard(usage: store.today, index: 2)
                    if settings.showsSystem {
                        SystemCard(index: 3)
                            .frame(width: 140)
                            .transition(.blurFade(scale: 0.9))
                    }
                }
                .padding(.horizontal, 30)
                .padding(.top, 10)
            }

            // Footer centred vertically in the space left under the cards.
            footer
                .padding(.horizontal, 34)
                .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 7) {
                ClaudeSpark(size: 14, spinning: store.isLoading)
                Text("Claude").font(.system(size: 12, weight: .semibold))
            }
            Spacer(minLength: model.notchSize.width + 20)
            if let plan = store.plan {
                Text(plan.uppercased())
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .tracking(0.8)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.claude.opacity(0.22)))
                    .foregroundStyle(Theme.claude)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 32)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(updatedLabel(now: ctx.date))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                    .contentTransition(.numericText())
            }
            if let err = store.error, store.session != nil {
                Text("· \(err)").font(.system(size: 10)).foregroundStyle(.orange.opacity(0.8))
            }
            Spacer()
            IconButton(symbol: "arrow.clockwise", spinning: store.isLoading) { store.refreshLocal() }
            IconButton(symbol: "power") { NSApp.terminate(nil) }
        }
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(msg).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
    }

    private func updatedLabel(now: Date) -> String {
        guard let d = store.lastUpdate else { return "caricamento…" }
        let s = Int(now.timeIntervalSince(d))
        let ago = s < 5 ? "aggiornato ora" : s < 60 ? "aggiornato \(s)s fa" : "aggiornato \(s / 60)m fa"
        let n = max(0, Int(store.nextAPIFetch.timeIntervalSince(now)))
        let next = n < 60 ? "\(n)s" : "\(n / 60)m \(n % 60)s"
        return "\(ago) · prossimo tra \(next)"
    }
}

struct GaugeCard: View {
    let title: String
    let window: LimitWindow?
    let index: Int
    @State private var shown: Double = 0

    var body: some View {
        let target = window?.used ?? 0
        let tint = Theme.tint(window?.used)
        VStack(spacing: 7) {
            ZStack {
                Circle().stroke(.white.opacity(0.08), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: shown)
                    .stroke(
                        AngularGradient(colors: [tint.opacity(0.35), tint],
                                        center: .center,
                                        startAngle: .degrees(0),
                                        endAngle: .degrees(max(shown, 0.001) * 360)),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: tint.opacity(0.55), radius: 6)
                VStack(spacing: -1) {
                    CountingText(value: shown * 100, format: { "\(Int($0.rounded()))" })
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("% usato").font(.system(size: 8, weight: .semibold)).opacity(0.5)
                }
                .foregroundStyle(.white)
            }
            .frame(width: 70, height: 70)

            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Text(resetLabel(now: ctx.date))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity)
        .modifier(CardBackground())
        .modifier(StaggerIn(index: index))
        .onAppear {
            withAnimation(.spring(response: 1.0, dampingFraction: 0.82).delay(0.12 + Double(index) * 0.08)) { shown = target }
        }
        .onChange(of: target) { _, new in
            withAnimation(.spring(response: 1.0, dampingFraction: 0.82)) { shown = new }
        }
    }

    private func resetLabel(now: Date) -> String {
        guard let r = window?.resetsAt else { return "—" }
        let s = Int(r.timeIntervalSince(now))
        if s <= 0 { return "reset ora" }
        if s < 86_400 {
            let h = s / 3600, m = (s % 3600) / 60
            return h > 0 ? "reset tra \(h)h \(m)m" : "reset tra \(m)m"
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "EEE HH:mm"
        return "reset \(f.string(from: r))"
    }
}

struct TodayCard: View {
    let usage: LocalUsage
    let index: Int
    @State private var grown = false

    var body: some View {
        let peak = max(usage.hourly.max() ?? 0, 1)
        let nowHour = Calendar.current.component(.hour, from: Date())
        VStack(alignment: .leading, spacing: 6) {
            Text("OGGI").font(.system(size: 9, weight: .heavy)).tracking(1).foregroundStyle(Theme.claude)
            CountingText(value: Double(usage.tokens), format: compact)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .animation(.spring(response: 1.1, dampingFraction: 0.9), value: usage.tokens)
            Text("token · \(usage.messages) risposte")
                .font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.45))

            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<24, id: \.self) { h in
                    let v = CGFloat(usage.hourly[h]) / CGFloat(peak)
                    RoundedRectangle(cornerRadius: 1.2)
                        .fill(h == nowHour ? Theme.claude : .white.opacity(h < nowHour ? 0.35 : 0.1))
                        .frame(height: grown ? max(2, v * 30) : 2)
                        .animation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.15 + Double(h) * 0.015), value: grown)
                }
            }
            .frame(height: 30, alignment: .bottom)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardBackground())
        .modifier(StaggerIn(index: index))
        .onAppear { grown = true }
    }

    private func compact(_ v: Double) -> String {
        switch v {
        case 1_000_000_000...: return String(format: "%.2fB", v / 1e9)
        case 1_000_000...: return String(format: "%.1fM", v / 1e6)
        case 1_000...: return String(format: "%.0fK", v / 1e3)
        default: return "\(Int(v))"
        }
    }
}

/// Live CPU / RAM rings (only the enabled ones).
struct SystemCard: View {
    let index: Int
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var system = SystemMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SISTEMA").font(.system(size: 9, weight: .heavy)).tracking(1).foregroundStyle(Theme.claude)
                Spacer()
                Circle().fill(Theme.tint(0)).frame(width: 5, height: 5)
                    .modifier(LivePulse())
            }
            HStack(spacing: 10) {
                if settings.showCPU { metric("CPU", system.cpu, detail: "\(ProcessInfo.processInfo.activeProcessorCount) core") }
                if settings.showRAM {
                    metric("RAM", system.ram, detail: String(format: "%.1f/%.0f GB", system.ramUsedGB, system.ramTotalGB))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardBackground())
        .modifier(StaggerIn(index: index))
    }

    private func metric(_ title: String, _ v: Double, detail: String?) -> some View {
        let tint = Theme.tint(v)
        return VStack(spacing: 5) {
            ZStack {
                Circle().stroke(.white.opacity(0.08), lineWidth: 5)
                Circle().trim(from: 0, to: v)
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: tint.opacity(0.5), radius: 4)
                CountingText(value: v * 100, format: { "\(Int($0.rounded()))" })
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            .animation(.spring(response: 0.6, dampingFraction: 0.85), value: v)
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            Text(detail ?? "").font(.system(size: 8.5, weight: .medium)).foregroundStyle(.white.opacity(0.4))
        }
    }
}

/// Gentle blinking "live" dot.
struct LivePulse: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0.25)
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true } }
    }
}

// MARK: - Building blocks

/// Text whose number interpolates frame by frame (count-up effect).
struct CountingText: View, Animatable {
    var value: Double
    let format: (Double) -> String
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View { Text(format(value)).monospacedDigit() }
}

/// Claude-style starburst glyph; spins while loading, breathes otherwise.
struct ClaudeSpark: View {
    let size: CGFloat
    let spinning: Bool
    @State private var breathe = false

    var body: some View {
        TimelineView(.animation(paused: !spinning)) { ctx in
            let angle = spinning ? ctx.date.timeIntervalSinceReferenceDate * 240 : 0
            ZStack {
                ForEach(0..<10, id: \.self) { i in
                    Capsule()
                        .fill(Theme.claude)
                        .frame(width: size * 0.13, height: size * (i.isMultiple(of: 2) ? 0.5 : 0.38))
                        .offset(y: -size * 0.22)
                        .rotationEffect(.degrees(Double(i) * 36))
                }
            }
            .frame(width: size, height: size)
            .rotationEffect(.degrees(angle.truncatingRemainder(dividingBy: 360)))
        }
        .scaleEffect(breathe ? 1.0 : 0.86)
        .shadow(color: Theme.claude.opacity(breathe ? 0.7 : 0.2), radius: 4)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

struct IconButton: View {
    let symbol: String
    var spinning = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 0.7).repeatForever(autoreverses: false) : .default, value: spinning)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(hover ? 0.16 : 0.07)))
                .foregroundStyle(.white.opacity(hover ? 1 : 0.6))
                .scaleEffect(hover ? 1.1 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(response: 0.25)) { hover = h } }
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(height: 128, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.045))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.06), lineWidth: 1))
            )
    }
}

/// Each card drops in slightly after the previous one.
struct StaggerIn: ViewModifier {
    let index: Int
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : -14)
            .scaleEffect(shown ? 1 : 0.92, anchor: .top)
            .blur(radius: shown ? 0 : 6)
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.78).delay(0.05 + Double(index) * 0.06)) { shown = true }
            }
    }
}

private struct BlurFadeModifier: ViewModifier {
    let active: Bool
    let scale: CGFloat
    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .blur(radius: active ? 8 : 0)
            .scaleEffect(active ? scale : 1, anchor: .top)
    }
}

extension AnyTransition {
    static func blurFade(scale: CGFloat) -> AnyTransition {
        .modifier(active: BlurFadeModifier(active: true, scale: scale),
                  identity: BlurFadeModifier(active: false, scale: scale))
    }
}

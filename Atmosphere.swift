import SwiftUI

private struct SkyOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct AtmosphereBackdrop: View {
    let mode: NivviMode
    let scroll: CGFloat
    let animate: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: animate ? 0.12 : 60)) { context in
            let time = animate ? context.date.timeIntervalSinceReferenceDate : 0
            Canvas { canvas, size in
                drawSky(canvas, size: size)
                if mode == .night {
                    drawStars(canvas, size: size, time: time)
                } else {
                    drawClouds(canvas, size: size, time: time)
                    drawBirds(canvas, size: size, time: time)
                }
            }
        }
        .animation(.easeInOut(duration: 1.4), value: mode)
        .accessibilityHidden(true)
    }

    private func drawSky(_ canvas: GraphicsContext, size: CGSize) {
        let nightTop = Color(red: 0.01, green: 0.05, blue: 0.12)
        let nightBottom = Color(red: 0.02, green: 0.13, blue: 0.23)
        let dayTop = Color(red: 0.863, green: 0.933, blue: 1.0)
        let dayMid = Color(red: 0.929, green: 0.965, blue: 1.0)
        let dayBottom = Color(red: 0.969, green: 0.980, blue: 1.0)
        let colors = mode == .night ? [nightTop, nightBottom] : [dayTop, dayMid, dayBottom]
        canvas.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(colors: colors),
                startPoint: CGPoint(x: size.width / 2, y: 0),
                endPoint: CGPoint(x: size.width / 2, y: size.height)
            )
        )
        if mode == .day { drawSun(canvas, size: size) }
    }

    private func drawSun(_ canvas: GraphicsContext, size: CGSize) {
        // Small disc, upper-right, clear of settings and the theme toggle.
        let center = CGPoint(x: size.width * 0.90, y: size.height * 0.09)
        var glow = canvas
        glow.opacity = 0.28
        glow.fill(
            Path(ellipseIn: CGRect(x: center.x - 22, y: center.y - 22, width: 44, height: 44)),
            with: .color(Color(red: 1, green: 0.92, blue: 0.62))
        )
        canvas.fill(
            Path(ellipseIn: CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)),
            with: .color(Color(red: 1, green: 0.94, blue: 0.72))
        )
    }

    private func drawClouds(_ canvas: GraphicsContext, size: CGSize, time: Double) {
        let shift = scroll * 0.04
        for cloud in Self.clouds {
            let span = size.width + cloud.width
            let travel = animateTravel(time: time, speed: cloud.speed, start: cloud.start, span: span)
            let x = travel - cloud.width * 0.5
            let y = cloud.y * size.height + shift
            var ctx = canvas
            ctx.opacity = cloud.opacity
            let puff = Color.white
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: cloud.width, height: cloud.height)), with: .color(puff))
            ctx.fill(Path(ellipseIn: CGRect(x: x + cloud.width * 0.22, y: y - cloud.height * 0.35, width: cloud.width * 0.55, height: cloud.height * 0.85)), with: .color(puff))
            ctx.fill(Path(ellipseIn: CGRect(x: x + cloud.width * 0.48, y: y - cloud.height * 0.12, width: cloud.width * 0.42, height: cloud.height * 0.7)), with: .color(puff))
        }
    }

    private func drawStars(_ canvas: GraphicsContext, size: CGSize, time: Double) {
        let shift = scroll * 0.08
        for star in Self.stars {
            let x = star.x * size.width
            let y = (star.y * size.height + shift).truncatingRemainder(dividingBy: size.height + 40) - 20
            let twinkle = 0.22 + 0.45 * (0.5 + 0.5 * sin(time * star.speed + star.phase))
            var ctx = canvas
            ctx.opacity = twinkle * 0.85
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: star.size, height: star.size)), with: .color(.white.opacity(0.9)))
        }
    }

    private func drawBirds(_ canvas: GraphicsContext, size: CGSize, time: Double) {
        // A pair, only now and then, in open sky — never over the reading cards.
        let cycle = time.truncatingRemainder(dividingBy: 52)
        guard cycle < 11 || (cycle > 28 && cycle < 37) else { return }
        let shift = scroll * 0.10
        for bird in Self.birds {
            let span = size.width + 180
            let x = ((time * bird.speed) + bird.start).truncatingRemainder(dividingBy: span) - 80
            let y = bird.y * size.height + shift * bird.depth
            let flap = 0.35 + 0.45 * sin(time * bird.flap)
            var ctx = canvas
            ctx.opacity = 0.10 + 0.08 * bird.depth
            ctx.translateBy(x: x, y: y)
            ctx.stroke(
                Self.wingPath(size: bird.size, flap: flap),
                with: .color(Color(red: 0.09, green: 0.17, blue: 0.26).opacity(0.40)),
                style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private func animateTravel(time: Double, speed: Double, start: Double, span: CGFloat) -> CGFloat {
        CGFloat(((time * speed) + start).truncatingRemainder(dividingBy: Double(span)))
    }

    private static func wingPath(size: CGFloat, flap: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: -size, y: -size * 0.15 * flap))
        path.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: -size * 0.45, y: -size * 0.55 * flap))
        path.addQuadCurve(to: CGPoint(x: size, y: -size * 0.1 * flap), control: CGPoint(x: size * 0.45, y: -size * 0.5 * flap))
        return path
    }

    private struct Star { let x: CGFloat; let y: CGFloat; let size: CGFloat; let speed: Double; let phase: Double }
    private struct Bird { let y: CGFloat; let size: CGFloat; let speed: Double; let start: Double; let flap: Double; let depth: CGFloat }
    private struct Cloud { let y: CGFloat; let width: CGFloat; let height: CGFloat; let speed: Double; let start: Double; let opacity: Double }

    private static let stars: [Star] = {
        var list: [Star] = []
        var seed: UInt64 = 2_026_09_15
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Double(seed % 10_000) / 10_000
        }
        for _ in 0..<52 {
            list.append(Star(x: next(), y: next(), size: 0.8 + next() * 1.8, speed: 0.35 + next() * 0.9, phase: next() * .pi * 2))
        }
        return list
    }()

    private static let birds: [Bird] = [
        Bird(y: 0.17, size: 10, speed: 14, start: 30, flap: 2.8, depth: 0.4),
        Bird(y: 0.20, size: 8, speed: 14, start: 48, flap: 3.1, depth: 0.35)
    ]

    private static let clouds: [Cloud] = [
        Cloud(y: 0.11, width: 92, height: 22, speed: 2.2, start: 40, opacity: 0.22),
        Cloud(y: 0.26, width: 70, height: 18, speed: 1.6, start: 180, opacity: 0.16),
        Cloud(y: 0.38, width: 110, height: 24, speed: 1.2, start: 90, opacity: 0.12)
    ]
}

struct AtmosphereScroll: ViewModifier {
    @Binding var offset: CGFloat
    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: SkyOffsetKey.self, value: geo.frame(in: .named("nivvi-sky")).minY)
                }
            )
            .onPreferenceChange(SkyOffsetKey.self) { offset = $0 }
    }
}

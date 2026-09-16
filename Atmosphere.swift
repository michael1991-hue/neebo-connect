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
        let dayTop = Color(red: 0.74, green: 0.82, blue: 0.79)
        let dayBottom = Color(red: 0.62, green: 0.73, blue: 0.72)
        let top = mode == .night ? nightTop : dayTop
        let bottom = mode == .night ? nightBottom : dayBottom
        canvas.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(colors: [top, bottom]),
                startPoint: CGPoint(x: size.width / 2, y: 0),
                endPoint: CGPoint(x: size.width / 2, y: size.height)
            )
        )
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
        let shift = scroll * 0.14
        for bird in Self.birds {
            let span = size.width + 160
            let x = ((time * bird.speed) + bird.start).truncatingRemainder(dividingBy: span) - 80
            let y = bird.y * size.height + shift * bird.depth
            let flap = 0.35 + 0.45 * sin(time * bird.flap)
            var ctx = canvas
            ctx.opacity = 0.18 + 0.10 * bird.depth
            ctx.translateBy(x: x, y: y)
            ctx.stroke(Self.wingPath(size: bird.size, flap: flap), with: .color(Color(red: 0.12, green: 0.22, blue: 0.34).opacity(0.45)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
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
        Bird(y: 0.14, size: 11, speed: 18, start: 40, flap: 3.2, depth: 0.35),
        Bird(y: 0.22, size: 16, speed: 13, start: 180, flap: 2.6, depth: 0.7),
        Bird(y: 0.31, size: 9, speed: 22, start: 90, flap: 3.8, depth: 0.25),
        Bird(y: 0.18, size: 13, speed: 15, start: 260, flap: 2.9, depth: 0.5)
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

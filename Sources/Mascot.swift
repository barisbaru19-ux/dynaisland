import AppKit
import SwiftUI

// MARK: - Types

enum MascotKind: String, CaseIterable {
    case moci, kucing, bit, off

    var title: String {
        switch self {
        case .moci: return "Moci"
        case .kucing: return "Kucing"
        case .bit: return "Bit (robot pixel)"
        case .off: return "Tanpa maskot"
        }
    }

    var shortName: String {
        switch self {
        case .moci: return "Moci"
        case .kucing: return "Kucing"
        case .bit: return "Bit"
        case .off: return ""
        }
    }
}

enum MascotMood: Equatable {
    case idle       // floats, blinks, eyes follow the cursor
    case music      // dances to the beat
    case sleep      // Mac untouched for a while: eyes shut, "z z"
    case happy      // island opened, file saved, focus block done
    case eating     // a file is being dragged onto the island
    case charging   // charger plugged in
    case tired      // battery low
    case surprised  // woken up

    /// A file drag always wins; otherwise a short reaction overrides the resting mood.
    static func resolve(base: MascotMood, reaction: MascotReaction?, at now: Date) -> MascotMood {
        if base == .eating { return .eating }
        if let reaction = reaction, reaction.until > now { return reaction.mood }
        return base
    }
}

struct MascotReaction: Equatable {
    var mood: MascotMood
    var until: Date
}

// MARK: - View

/// The mascot, drawn in code and animated every frame (no image files).
@MainActor
struct MascotView: View {
    @ObservedObject var model: IslandModel
    var size: CGFloat = 24
    /// Draws this mascot instead of the chosen one (previews in Settings).
    var kind: MascotKind? = nil

    var body: some View {
        MascotHost(scene: MascotScene(kind: kind ?? model.mascot,
                                      base: model.mascotBaseMood,
                                      reaction: model.mascotReaction))
            // A little extra room on top for ears and hops; layout only counts `size`.
            .frame(width: size * MascotPainter.aspect, height: size * MascotPainter.headroom)
            .frame(width: size * MascotPainter.aspect, height: size, alignment: .bottom)
            .allowsHitTesting(false)
    }

    /// Where the cursor is relative to the top of the screen: x -1…1 (left…right), y 0…1 (down).
    static func cursorLook() -> CGPoint {
        guard let screen = NSScreen.screens.first else { return .zero }
        let mouse = NSEvent.mouseLocation
        let anchor = CGPoint(x: screen.frame.midX - 125, y: screen.frame.maxY - 16)
        return CGPoint(x: max(-1, min(1, (mouse.x - anchor.x) / 360)),
                       y: max(0, min(1, (anchor.y - mouse.y) / 420)))
    }
}

struct MascotScene: Equatable {
    var kind: MascotKind
    var base: MascotMood
    var reaction: MascotReaction?
}

/// Draws the mascot in a plain AppKit view with its own timer. Animating with SwiftUI made
/// every frame re-render the whole island window (layout, constraints, Metal), which cost
/// far more CPU than the drawing itself. A redraw here touches only this little view.
struct MascotHost: NSViewRepresentable {
    var scene: MascotScene

    func makeNSView(context: Context) -> MascotLayerView {
        let view = MascotLayerView()
        view.scene = scene
        return view
    }

    func updateNSView(_ view: MascotLayerView, context: Context) {
        if view.scene != scene { view.scene = scene }
    }
}

final class MascotLayerView: NSView {
    var scene = MascotScene(kind: .off, base: .idle, reaction: nil) {
        didSet {
            needsDisplay = true
            if oldValue.base != scene.base { restartTimer() }
        }
    }
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }   // same y-down space as the drawing code
    override var isOpaque: Bool { false }
    /// Never takes clicks, hovers or file drags: those belong to the island around it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restartTimer()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        needsDisplay = true
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        // Every frame costs CPU all day, so few frames. While it sleeps nobody has touched
        // the Mac for 2 minutes, so even fewer.
        let interval = scene.base == .sleep ? 1.0 / 4.0 : 1.0 / 15.0
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let now = Date()
        let mood = MascotMood.resolve(base: scene.base, reaction: scene.reaction, at: now)
        MascotPainter.draw(scene.kind, mood: mood, time: now.timeIntervalSinceReferenceDate,
                           look: MascotView.cursorLook(), in: MascotPen(cg), size: bounds.size)
    }
}

/// The few drawing calls the mascots use, on Core Graphics. A value type like SwiftUI's
/// GraphicsContext: a copy keeps its own transform.
struct MascotPen {
    enum Shading { case color(Color) }

    private let cg: CGContext
    private var transform = CGAffineTransform.identity

    init(_ cg: CGContext) { self.cg = cg }

    mutating func translateBy(x: CGFloat, y: CGFloat) { transform = transform.translatedBy(x: x, y: y) }
    mutating func scaleBy(x: CGFloat, y: CGFloat) { transform = transform.scaledBy(x: x, y: y) }
    mutating func rotate(by angle: Angle) { transform = transform.rotated(by: CGFloat(angle.radians)) }

    func fill(_ path: Path, with shading: Shading) {
        drawing { cg in
            cg.setFillColor(shading.cgColor)
            cg.addPath(path.cgPath)
            cg.fillPath()
        }
    }

    func stroke(_ path: Path, with shading: Shading, style: StrokeStyle) {
        drawing { cg in
            cg.setStrokeColor(shading.cgColor)
            cg.setLineWidth(style.lineWidth)
            cg.setLineCap(style.lineCap)
            cg.addPath(path.cgPath)
            cg.strokePath()
        }
    }

    /// Text centred on `point`, like GraphicsContext.draw(_:at:).
    func draw(_ string: String, size: CGFloat, weight: NSFont.Weight, rounded: Bool,
              color: Color, at point: CGPoint) {
        var font = NSFont.systemFont(ofSize: size, weight: weight)
        if rounded, let descriptor = font.fontDescriptor.withDesign(.rounded),
           let roundedFont = NSFont(descriptor: descriptor, size: size) {
            font = roundedFont
        }
        let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor(color)])
        let box = text.size()
        drawing { cg in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            text.draw(at: CGPoint(x: point.x - box.width / 2, y: point.y - box.height / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawing(_ body: (CGContext) -> Void) {
        cg.saveGState()
        cg.concatenate(transform)
        body(cg)
        cg.restoreGState()
    }
}

private extension MascotPen.Shading {
    var cgColor: CGColor {
        switch self {
        case .color(let color): return NSColor(color).cgColor
        }
    }
}

// MARK: - Drawing

/// Draws the mascots in a 40 × 32 design space: the character in the left 32 × 32,
/// effects ("z z", lightning, notes, sparkles) in the strip on the right.
/// The canvas is 4 units taller than that, so ears and jumps never get cut off at the top.
enum MascotPainter {
    static let aspect: CGFloat = 40.0 / 32.0
    static let headroom: CGFloat = 36.0 / 32.0

    private static let ink = rgb(0x1A1A1A)
    private static let mouthDark = rgb(0x4A1B0C)

    static func draw(_ kind: MascotKind, mood: MascotMood, time t: Double, look: CGPoint,
                     in context: MascotPen, size: CGSize) {
        guard kind != .off, size.height > 0 else { return }
        var canvas = context
        let scale = size.height / 36
        canvas.scaleBy(x: scale, y: scale)
        canvas.translateBy(x: 0, y: 4)

        // Whole-body motion, pivoting on the bottom centre.
        let motion = Motion(mood: mood, time: t, pixel: kind == .bit)
        var body = canvas
        body.translateBy(x: 16 + motion.dx, y: 31 + motion.dy)
        body.rotate(by: .degrees(motion.angle))
        body.scaleBy(x: motion.sx, y: motion.sy)
        body.translateBy(x: -16, y: -31)

        let face = Face(mood: mood, time: t, look: look)
        switch kind {
        case .moci: drawMoci(in: body, face: face)
        case .kucing: drawCat(in: body, face: face, time: t)
        case .bit: drawBit(in: body, face: face, mood: mood, time: t)
        case .off: break
        }
        drawEffects(in: canvas, mood: mood, time: t)
    }

    // MARK: Characters

    private static func drawMoci(in ctx: MascotPen, face: Face) {
        ctx.fill(Path(ellipseIn: CGRect(x: 3, y: 9.5, width: 26, height: 21)), with: .color(rgb(0xF4F1EA)))
        ctx.fill(Path(ellipseIn: CGRect(x: 7, y: 11.5, width: 6, height: 3)), with: .color(Color.white.opacity(0.85)))
        let cheek = rgb(0xED93B1).opacity(0.85)
        ctx.fill(Path(ellipseIn: CGRect(x: 6, y: 21.3, width: 4, height: 2.4)), with: .color(cheek))
        ctx.fill(Path(ellipseIn: CGRect(x: 22, y: 21.3, width: 4, height: 2.4)), with: .color(cheek))
        drawEyes(in: ctx, face: face,
                 centers: [CGPoint(x: 11.5, y: 18.5), CGPoint(x: 20.5, y: 18.5)], rx: 1.8, ry: 2.4)
        drawMouth(in: ctx, face.mouth, at: CGPoint(x: 16, y: 22.6))
    }

    private static func drawCat(in ctx: MascotPen, face: Face, time t: Double) {
        let fur = rgb(0xEF9F27)
        let innerEar = rgb(0xF0997B)
        // The right ear twitches every few seconds.
        let twitch: CGFloat = t.truncatingRemainder(dividingBy: 6.5) > 6.3 ? 1.2 : 0

        ctx.fill(triangle((5, 14), (8, 3), (14, 9)), with: .color(fur))
        ctx.fill(triangle((27, 14), (24 + twitch, 3 + twitch), (18, 9)), with: .color(fur))
        ctx.fill(triangle((7.5, 10), (8.6, 5.5), (11.5, 8.5)), with: .color(innerEar))
        ctx.fill(triangle((24.5, 10), (23.4 + twitch, 5.5 + twitch), (20.5, 8.5)), with: .color(innerEar))
        ctx.fill(Path(ellipseIn: CGRect(x: 4, y: 8.5, width: 24, height: 21)), with: .color(fur))

        var stripes = Path()
        let marks: [(CGFloat, CGFloat)] = [(14, 10), (16, 9.4), (18, 10)]
        for (x, top) in marks {
            stripes.move(to: CGPoint(x: x, y: top))
            stripes.addLine(to: CGPoint(x: x, y: top + 2.6))
        }
        ctx.stroke(stripes, with: .color(rgb(0xBA7517)), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))

        var whiskers = Path()
        whiskers.move(to: CGPoint(x: 2.5, y: 20)); whiskers.addLine(to: CGPoint(x: 8.5, y: 20.8))
        whiskers.move(to: CGPoint(x: 2.5, y: 23.2)); whiskers.addLine(to: CGPoint(x: 8.5, y: 22.4))
        whiskers.move(to: CGPoint(x: 29.5, y: 20)); whiskers.addLine(to: CGPoint(x: 23.5, y: 20.8))
        whiskers.move(to: CGPoint(x: 29.5, y: 23.2)); whiskers.addLine(to: CGPoint(x: 23.5, y: 22.4))
        ctx.stroke(whiskers, with: .color(rgb(0xFAC775)), style: StrokeStyle(lineWidth: 0.7, lineCap: .round))

        drawEyes(in: ctx, face: face,
                 centers: [CGPoint(x: 11.5, y: 18), CGPoint(x: 20.5, y: 18)], rx: 1.7, ry: 2.5)
        ctx.fill(triangle((15, 21), (17, 21), (16, 22.2)), with: .color(rgb(0xD4537E)))

        if case .smile = face.mouth {
            // Cat mouth: ω
            var mouth = Path()
            mouth.move(to: CGPoint(x: 16, y: 22.2))
            mouth.addQuadCurve(to: CGPoint(x: 14.2, y: 23.1), control: CGPoint(x: 15.6, y: 23.7))
            mouth.move(to: CGPoint(x: 16, y: 22.2))
            mouth.addQuadCurve(to: CGPoint(x: 17.8, y: 23.1), control: CGPoint(x: 16.4, y: 23.7))
            ctx.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
        } else {
            drawMouth(in: ctx, face.mouth, at: CGPoint(x: 16, y: 23.7))
        }
    }

    private static func drawBit(in ctx: MascotPen, face: Face, mood: MascotMood, time t: Double) {
        let green = rgb(0x97C459)
        let dark = rgb(0x639922)
        let mouthLine = rgb(0x3B6D11)
        let mouthHole = rgb(0x173404)
        let bulb: Color
        switch mood {
        case .charging: bulb = sin(t * 6) > 0 ? rgb(0xFAC775) : rgb(0xEF9F27)
        case .sleep, .tired: bulb = dark
        default: bulb = rgb(0xC0DD97)
        }

        func px(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Color) {
            ctx.fill(Path(CGRect(x: x, y: y, width: w, height: h)), with: .color(color))
        }

        px(15, 3, 2, 5, green)     // antenna
        px(13, 1, 6, 3, bulb)
        px(4, 13, 2, 7, dark)      // side bolts
        px(26, 13, 2, 7, dark)
        px(6, 8, 20, 17, green)    // head
        px(8, 25, 5, 4, dark)      // feet
        px(19, 25, 5, 4, dark)

        // The face moves in whole pixels.
        let lx = face.look.x.rounded()
        let ly = face.look.y.rounded()
        for x: CGFloat in [10, 19] {
            switch face.eyes {
            case .open(let k):
                let h = max(1, (5 * k).rounded())
                px(x + lx, 13 + ly + (5 - h) / 2, 3, h, ink)
            case .closed:
                px(x, 16, 3, 1, ink)
            case .happy:
                px(x, 16, 1, 1, ink)
                px(x + 1, 15, 1, 1, ink)
                px(x + 2, 16, 1, 1, ink)
            }
        }

        switch face.mouth {
        case .smile:
            px(12, 20, 1, 1, mouthLine)
            px(13, 21, 6, 1, mouthLine)
            px(19, 20, 1, 1, mouthLine)
        case .grin:
            px(12, 20, 8, 3, mouthHole)
        case .open(let a):
            px(13, 20, 6, max(1, (1 + 3 * a).rounded()), mouthHole)
        case .flat:
            px(13, 21, 6, 1, mouthLine)
        case .o:
            px(15, 20, 2, 3, mouthHole)
        }
    }

    // MARK: Face parts

    private static func drawEyes(in ctx: MascotPen, face: Face, centers: [CGPoint], rx: CGFloat, ry: CGFloat) {
        let line = StrokeStyle(lineWidth: 0.9, lineCap: .round)
        for c in centers {
            switch face.eyes {
            case .open(let k):
                let p = CGPoint(x: c.x + face.look.x, y: c.y + face.look.y)
                let h = ry * k
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - rx, y: p.y - h, width: rx * 2, height: h * 2)),
                         with: .color(ink))
                if k > 0.6 {   // little shine
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x + rx * 0.1, y: p.y - h * 0.8, width: rx * 0.7, height: rx * 0.7)),
                             with: .color(.white))
                }
            case .closed:
                var path = Path()
                path.move(to: CGPoint(x: c.x - rx - 0.2, y: c.y))
                path.addQuadCurve(to: CGPoint(x: c.x + rx + 0.2, y: c.y), control: CGPoint(x: c.x, y: c.y + 1.6))
                ctx.stroke(path, with: .color(ink), style: line)
            case .happy:
                var path = Path()
                path.move(to: CGPoint(x: c.x - rx - 0.2, y: c.y + 0.8))
                path.addQuadCurve(to: CGPoint(x: c.x + rx + 0.2, y: c.y + 0.8), control: CGPoint(x: c.x, y: c.y - 1.8))
                ctx.stroke(path, with: .color(ink), style: line)
            }
        }
    }

    private static func drawMouth(in ctx: MascotPen, _ mouth: Face.Mouth, at m: CGPoint) {
        let line = StrokeStyle(lineWidth: 0.9, lineCap: .round)
        switch mouth {
        case .smile:
            var path = Path()
            path.move(to: CGPoint(x: m.x - 1.5, y: m.y))
            path.addQuadCurve(to: CGPoint(x: m.x + 1.5, y: m.y), control: CGPoint(x: m.x, y: m.y + 1.6))
            ctx.stroke(path, with: .color(ink), style: line)
        case .grin:
            var path = Path()
            path.move(to: CGPoint(x: m.x - 2, y: m.y - 0.3))
            path.addQuadCurve(to: CGPoint(x: m.x + 2, y: m.y - 0.3), control: CGPoint(x: m.x, y: m.y + 3.4))
            path.closeSubpath()
            ctx.fill(path, with: .color(mouthDark))
        case .open(let a):
            let w = 1.5 + 0.7 * a
            let h = 0.5 + 1.9 * a
            ctx.fill(Path(ellipseIn: CGRect(x: m.x - w, y: m.y - h * 0.6, width: w * 2, height: h * 2)),
                     with: .color(mouthDark))
        case .flat:
            var path = Path()
            path.move(to: CGPoint(x: m.x - 1.2, y: m.y + 0.6))
            path.addLine(to: CGPoint(x: m.x + 1.2, y: m.y + 0.6))
            ctx.stroke(path, with: .color(ink), style: line)
        case .o:
            ctx.fill(Path(ellipseIn: CGRect(x: m.x - 1, y: m.y - 0.6, width: 2, height: 2.6)), with: .color(mouthDark))
        }
    }

    // MARK: Effects beside the character

    private static func drawEffects(in ctx: MascotPen, mood: MascotMood, time t: Double) {
        switch mood {
        case .sleep:
            for i in 0..<2 {
                let phase = (t / 2.4 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                ctx.draw("z", size: i == 0 ? 9 : 7, weight: .heavy, rounded: true,
                         color: Color.white.opacity(sin(phase * .pi) * 0.9),
                         at: CGPoint(x: 31 + phase * 4, y: 14 - phase * 10))
            }
        case .charging:
            var bolt = Path()
            bolt.move(to: CGPoint(x: 35, y: 2))
            bolt.addLine(to: CGPoint(x: 30.5, y: 9))
            bolt.addLine(to: CGPoint(x: 33.5, y: 9))
            bolt.addLine(to: CGPoint(x: 32, y: 15))
            bolt.addLine(to: CGPoint(x: 37, y: 7.5))
            bolt.addLine(to: CGPoint(x: 34, y: 7.5))
            bolt.closeSubpath()
            ctx.fill(bolt, with: .color(rgb(0xFAC775).opacity(0.55 + 0.45 * (0.5 + 0.5 * sin(t * 4)))))
        case .tired:
            let drip = (t / 2.2).truncatingRemainder(dividingBy: 1)
            let x = 30.5
            let y = 9 + drip * 5
            var drop = Path()
            drop.move(to: CGPoint(x: x, y: y - 2.6))
            drop.addCurve(to: CGPoint(x: x, y: y + 1.8),
                          control1: CGPoint(x: x + 0.4, y: y - 1),
                          control2: CGPoint(x: x + 2.2, y: y + 1.8))
            drop.addCurve(to: CGPoint(x: x, y: y - 2.6),
                          control1: CGPoint(x: x - 2.2, y: y + 1.8),
                          control2: CGPoint(x: x - 0.4, y: y - 1))
            ctx.fill(drop, with: .color(rgb(0x85B7EB).opacity(1 - drip * 0.7)))
        case .music:
            let phase = (t / 1.6).truncatingRemainder(dividingBy: 1)
            ctx.draw("♪", size: 10, weight: .bold, rounded: false,
                     color: Color.white.opacity(sin(phase * .pi) * 0.9),
                     at: CGPoint(x: 34 + sin(phase * 6) * 1.2, y: 17 - phase * 11))
        case .happy:
            let spots = [CGPoint(x: 33, y: 6), CGPoint(x: 37, y: 13)]
            for (i, spot) in spots.enumerated() {
                let twinkle = 0.5 + 0.5 * sin(t * 5 + Double(i) * 2)
                sparkle(in: ctx, at: spot, radius: CGFloat(1 + 1.6 * twinkle), opacity: twinkle)
            }
        case .surprised:
            ctx.draw("!", size: 11, weight: .heavy, rounded: true, color: rgb(0xFAC775), at: CGPoint(x: 33, y: 8))
        case .idle, .eating:
            break
        }
    }

    private static func sparkle(in ctx: MascotPen, at c: CGPoint, radius r: CGFloat, opacity: Double) {
        var path = Path()
        path.move(to: CGPoint(x: c.x, y: c.y - r))
        path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: c)
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: c)
        path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: c)
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: c)
        ctx.fill(path, with: .color(rgb(0xFAC775).opacity(opacity)))
    }

    // MARK: Helpers

    private static func triangle(_ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat), _ c: (CGFloat, CGFloat)) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: a.0, y: a.1))
        path.addLine(to: CGPoint(x: b.0, y: b.1))
        path.addLine(to: CGPoint(x: c.0, y: c.1))
        path.closeSubpath()
        return path
    }

    private static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Animation curves

/// How the whole body moves in each mood.
private struct Motion {
    var dx: CGFloat = 0
    var dy: CGFloat = 0
    var angle: Double = 0
    var sx: CGFloat = 1
    var sy: CGFloat = 1

    init(mood: MascotMood, time t: Double, pixel: Bool) {
        switch mood {
        case .idle, .charging:
            let s = CGFloat(sin(t * 1.7))
            dy = s * 0.6
            sy = 1 + 0.015 * s
        case .music:
            let beat = t * 2.2 * Double.pi          // about 132 beats per minute
            let bounce = CGFloat(abs(sin(beat)))
            dy = -bounce * 2.2
            angle = sin(beat) * 7
            sx = 1 + 0.05 * (1 - bounce)
            sy = 1 - 0.05 * (1 - bounce)
        case .sleep:
            let s = CGFloat(sin(t * 2 * Double.pi / 3.2))
            sx = 1 - 0.03 * s
            sy = 1 + 0.035 * s
        case .happy:
            let h = CGFloat(max(0, sin(t * 2 * Double.pi * 1.4)))
            dy = -h * 3
            sx = 1 - 0.04 * h
            sy = 1 + 0.05 * h
        case .eating:
            let s = CGFloat(sin(t * 14))
            sx = 1 + 0.045 * s
            sy = 1 - 0.045 * s
        case .tired:
            dy = 0.8
            angle = sin(t * 0.9) * 2.5
            sy = 0.96
        case .surprised:
            dy = -1.5
            sx = 0.95
            sy = 1.07
        }
        if pixel {   // the robot moves in whole pixels and doesn't tilt
            dx = dx.rounded()
            dy = dy.rounded()
            angle = 0
        }
    }
}

/// Eyes and mouth for each mood.
private struct Face {
    enum Eyes { case open(CGFloat), closed, happy }
    enum Mouth { case smile, grin, open(CGFloat), flat, o }

    var eyes: Eyes
    var mouth: Mouth
    /// Pupil offset in design units.
    var look: CGPoint

    init(mood: MascotMood, time t: Double, look cursor: CGPoint) {
        let cycle = t.truncatingRemainder(dividingBy: 4.3)
        let longCycle = t.truncatingRemainder(dividingBy: 11.0)
        let blinking = cycle > 4.14 || (longCycle > 10.6 && longCycle < 10.72)
        let gaze = CGPoint(x: cursor.x * 1.5, y: cursor.y * 1.2 - 0.4)

        switch mood {
        case .idle, .charging:
            eyes = .open(blinking ? 0.1 : 1)
            mouth = .smile
            look = gaze
        case .music:
            let groove = sin(t * 0.8) > 0.55
            eyes = groove ? .happy : .open(blinking ? 0.1 : 1)
            mouth = groove ? .grin : .smile
            look = CGPoint(x: gaze.x * 0.5, y: gaze.y * 0.5)
        case .sleep:
            eyes = .closed
            mouth = .flat
            look = .zero
        case .happy:
            eyes = .happy
            mouth = .grin
            look = .zero
        case .eating:
            eyes = .open(0.85)
            mouth = .open(CGFloat(0.35 + 0.65 * abs(sin(t * 7))))
            look = gaze
        case .tired:
            eyes = .open(blinking ? 0.1 : 0.45)
            mouth = .flat
            look = CGPoint(x: gaze.x * 0.4, y: 0.6)
        case .surprised:
            eyes = .open(1.3)
            mouth = .o
            look = .zero
        }
    }
}

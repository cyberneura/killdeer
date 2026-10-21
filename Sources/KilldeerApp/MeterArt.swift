import AppKit
import KilldeerCore

/// Everything one menu bar picture depends on. Two equal frames are the same
/// picture, which is what lets the cache hand the same image back.
struct MeterFrame: Hashable {
    var style: MeterStyle
    /// The whole machine's level, 0 to `CPUMeter.steps`.
    var level: Int
    /// One level per bar or tile, for the styles that use cores; empty for
    /// the others, so that their keys do not change with the cores.
    var coreLevels: [Int]
    /// Which beat of the wing, for the flapping bird; 0 for the others.
    var flapFrame: Int
    /// Red for a runaway, as every style is.
    var warning: Bool
}

/// The pictures already drawn, by frame. The label is rebuilt on every
/// published change from the monitor, and rasterising the glyph each time
/// would redraw it several times a minute, or a dozen times a second while
/// the bird flaps. The whole-machine styles can only ever be a few dozen
/// pictures; the per-core styles have a key per combination of core levels,
/// which is why the cache is emptied rather than left to grow.
@MainActor
final class MeterImageCache {
    private var images: [MeterFrame: NSImage] = [:]
    private static let limit = 256

    func image(for frame: MeterFrame) -> NSImage {
        if let image = images[frame] { return image }
        if images.count >= Self.limit { images.removeAll(keepingCapacity: true) }
        let image = MeterArt.image(for: frame)
        images[frame] = image
        return image
    }
}

/// The menu bar picture for each `MeterStyle`.
///
/// Every picture is `height` points tall and drawn into a flipped context,
/// like the bird: y grows downwards, so "the bottom of the gauge" is the
/// largest y. Arcs are drawn as polylines from clock angles (degrees
/// clockwise from twelve) rather than with `addArc`, whose sense of clockwise
/// turns over with the context; the polyline reads the same way on the screen
/// whatever the context's handedness.
///
/// A template unless tinted, for the same reason as the bird: the menu bar
/// inverts a template for dark mode and for the moment the menu is open. The
/// lighter parts of a picture, a gauge's track or an idle core's tile, are the
/// same colour at a lower alpha, which a template keeps.
enum MeterArt {
    static let height: CGFloat = 18

    static func image(for frame: MeterFrame) -> NSImage {
        let tint: NSColor? = frame.warning ? .systemRed : nil
        switch frame.style {
        case .birdWithGauge:
            return KilldeerBird.menuBarImage(tint: tint, meter: (level: frame.level, steps: CPUMeter.steps))
        case .flappingBird:
            return KilldeerBird.menuBarImage(tint: tint, wingFrame: frame.flapFrame)
        case .ringGauge:
            return draw(width: height, tint: tint) { context, colour in
                ring(context, colour: colour, level: frame.level)
            }
        case .coreBars:
            let levels = frame.coreLevels.isEmpty ? [0] : frame.coreLevels
            return draw(width: coreBarsWidth(count: levels.count), tint: tint) { context, colour in
                coreBars(context, colour: colour, levels: levels)
            }
        case .coreHeatmap:
            let levels = frame.coreLevels.isEmpty ? [0] : frame.coreLevels
            return draw(width: heatmapWidth(count: levels.count), tint: tint) { context, colour in
                heatmap(context, colour: colour, levels: levels)
            }
        case .moonPhase:
            return draw(width: height, tint: tint) { context, colour in
                moon(context, colour: colour, level: frame.level)
            }
        case .weather:
            return draw(width: 20, tint: tint) { context, colour in
                weather(context, colour: colour, kind: WeatherKind.forLevel(frame.level))
            }
        case .coffeeCup:
            return draw(width: height, tint: tint) { context, colour in
                coffee(context, colour: colour, level: frame.level)
            }
        }
    }

    // MARK: - Canvas

    private static func draw(
        width: CGFloat,
        tint: NSColor?,
        body: @escaping (CGContext, NSColor) -> Void
    ) -> NSImage {
        let colour = tint ?? .black
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            body(context, colour)
            return true
        }
        image.isTemplate = tint == nil
        return image
    }

    /// A point on a circle at a clock angle, in a context where y grows
    /// downwards: twelve o'clock is straight up on the screen.
    private static func clockPoint(center: CGPoint, radius: CGFloat, degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(x: center.x + radius * CGFloat(sin(radians)),
                       y: center.y - radius * CGFloat(cos(radians)))
    }

    /// An arc from a clock angle, `sweep` degrees clockwise on the screen.
    private static func arc(center: CGPoint, radius: CGFloat, from start: Double, sweep: Double) -> CGPath {
        let path = CGMutablePath()
        let segments = max(1, Int((sweep / 5).rounded(.up)))
        for step in 0...segments {
            let degrees = start + sweep * Double(step) / Double(segments)
            let point = clockPoint(center: center, radius: radius, degrees: degrees)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    private static func line(_ context: CGContext, from start: CGPoint, to end: CGPoint) {
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
    }

    private static func fraction(_ level: Int) -> CGFloat {
        CGFloat(min(max(0, level), CPUMeter.steps)) / CGFloat(CPUMeter.steps)
    }

    // MARK: - Ring gauge

    private static func ring(_ context: CGContext, colour: NSColor, level: Int) {
        let center = CGPoint(x: height / 2, y: height / 2)
        let radius: CGFloat = 6.5
        context.setLineWidth(2.5)
        context.setLineCap(.round)
        // The track, so that an idle machine still shows where the ring is.
        colour.withAlphaComponent(0.3).setStroke()
        context.addPath(arc(center: center, radius: radius,
                            from: RingGauge.startDegrees, sweep: RingGauge.sweepDegrees))
        context.strokePath()
        let sweep = RingGauge.sweep(forLevel: level)
        guard sweep > 0 else { return }
        colour.setStroke()
        context.addPath(arc(center: center, radius: radius, from: RingGauge.startDegrees, sweep: sweep))
        context.strokePath()
    }

    // MARK: - Core bars

    private static let barWidth: CGFloat = 2
    private static let barGap: CGFloat = 1

    static func coreBarsWidth(count: Int) -> CGFloat {
        CGFloat(max(1, count)) * (barWidth + barGap) - barGap
    }

    private static func coreBars(_ context: CGContext, colour: NSColor, levels: [Int]) {
        let top: CGFloat = 2
        let bottom = height - 2
        for (index, level) in levels.enumerated() {
            let x = CGFloat(index) * (barWidth + barGap)
            let track = CGRect(x: x, y: top, width: barWidth, height: bottom - top)
            colour.withAlphaComponent(0.25).setFill()
            context.fill(track)
            let filled = track.height * fraction(level)
            guard filled > 0 else { continue }
            colour.setFill()
            context.fill(CGRect(x: x, y: bottom - filled, width: barWidth, height: filled))
        }
    }

    // MARK: - Core heatmap

    private static let tile: CGFloat = 5
    private static let tileGap: CGFloat = 1

    static func heatmapWidth(count: Int) -> CGFloat {
        CGFloat(HeatmapGrid.layout(count: count).columns) * (tile + tileGap) - tileGap
    }

    private static func heatmap(_ context: CGContext, colour: NSColor, levels: [Int]) {
        let grid = HeatmapGrid.layout(count: levels.count)
        let gridHeight = CGFloat(grid.rows) * (tile + tileGap) - tileGap
        let top = ((height - gridHeight) / 2).rounded()
        for (index, level) in levels.enumerated() {
            let row = index / grid.columns
            let column = index % grid.columns
            let rect = CGRect(x: CGFloat(column) * (tile + tileGap),
                              y: top + CGFloat(row) * (tile + tileGap),
                              width: tile, height: tile)
            // An idle core keeps a faint tile, so the grid shows every core
            // and the shape of the machine rather than only the busy ones.
            colour.withAlphaComponent(0.15 + 0.85 * fraction(level)).setFill()
            context.fill(rect)
        }
    }

    // MARK: - Moon phase

    private static func moon(_ context: CGContext, colour: NSColor, level: Int) {
        let center = CGPoint(x: height / 2, y: height / 2)
        let radius: CGFloat = 7
        let disc = CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
        // The dark side as a faint outline, so that a new moon is a moon and
        // not an empty status item.
        context.setLineWidth(1)
        colour.withAlphaComponent(0.35).setStroke()
        context.addEllipse(in: disc.insetBy(dx: 0.5, dy: 0.5))
        context.strokePath()
        guard level > 0 else { return }

        // The lit part: down the right-hand limb from the top, then back up
        // along the terminator, a half-ellipse whose width the phase sets.
        // At a new moon the terminator lies on that same limb and the shape
        // has no area; at full it is the left-hand limb and the shape is the
        // disc. The loop is simple either way, so the fill rule does not
        // matter.
        let terminator = CGFloat(MoonPhase.terminator(forLevel: level))
        let segments = 36
        let path = CGMutablePath()
        for step in 0...segments {
            let point = clockPoint(center: center, radius: radius,
                                   degrees: 180 * Double(step) / Double(segments))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        for step in 1...segments {
            let t = Double.pi * (1 - Double(step) / Double(segments))
            path.addLine(to: CGPoint(x: center.x + radius * terminator * CGFloat(sin(t)),
                                     y: center.y - radius * CGFloat(cos(t))))
        }
        path.closeSubpath()
        colour.setFill()
        context.addPath(path)
        context.fillPath()
    }

    // MARK: - Weather

    private static func weather(_ context: CGContext, colour: NSColor, kind: WeatherKind) {
        colour.setFill()
        colour.setStroke()
        context.setLineWidth(1.2)
        context.setLineCap(.round)
        switch kind {
        case .sun:
            sun(context, center: CGPoint(x: 10, y: 9), radius: 3.6, rays: 8, rayLength: 2.6)
        case .sunBehindCloud:
            sun(context, center: CGPoint(x: 7, y: 6.5), radius: 2.8, rays: 8, rayLength: 1.8)
            cloud(context, origin: CGPoint(x: 4, y: 7))
        case .cloud:
            cloud(context, origin: CGPoint(x: 2.5, y: 4.5))
        case .rain:
            cloud(context, origin: CGPoint(x: 2.5, y: 1))
            for x: CGFloat in [6, 10, 14] {
                line(context, from: CGPoint(x: x, y: 12.5), to: CGPoint(x: x - 1.2, y: 16))
            }
        case .thunder:
            cloud(context, origin: CGPoint(x: 2.5, y: 1))
            let bolt = CGMutablePath()
            bolt.move(to: CGPoint(x: 10.5, y: 10))
            bolt.addLine(to: CGPoint(x: 7, y: 14.5))
            bolt.addLine(to: CGPoint(x: 9.5, y: 14.5))
            bolt.addLine(to: CGPoint(x: 8, y: 18))
            bolt.addLine(to: CGPoint(x: 12.5, y: 13))
            bolt.addLine(to: CGPoint(x: 10, y: 13))
            bolt.addLine(to: CGPoint(x: 12, y: 10))
            bolt.closeSubpath()
            context.addPath(bolt)
            context.fillPath()
        }
    }

    private static func sun(_ context: CGContext, center: CGPoint, radius: CGFloat, rays: Int, rayLength: CGFloat) {
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                       width: 2 * radius, height: 2 * radius))
        for ray in 0..<rays {
            let degrees = 360 * Double(ray) / Double(rays)
            line(context,
                 from: clockPoint(center: center, radius: radius + 1.3, degrees: degrees),
                 to: clockPoint(center: center, radius: radius + 1.3 + rayLength, degrees: degrees))
        }
    }

    /// A cloud about 15 points wide and 9 tall with its top left at `origin`.
    /// Three discs and a base, filled one after another: painting them over
    /// each other unions them without caring which way each path winds.
    private static func cloud(_ context: CGContext, origin: CGPoint) {
        let discs = [
            CGRect(x: origin.x + 0.5, y: origin.y + 2.5, width: 6.5, height: 6.5),
            CGRect(x: origin.x + 4, y: origin.y, width: 8, height: 8),
            CGRect(x: origin.x + 9, y: origin.y + 2.5, width: 6, height: 6),
        ]
        for disc in discs { context.fillEllipse(in: disc) }
        context.addPath(CGPath(roundedRect: CGRect(x: origin.x + 1, y: origin.y + 5, width: 13.5, height: 4),
                               cornerWidth: 2, cornerHeight: 2, transform: nil))
        context.fillPath()
    }

    // MARK: - Coffee cup

    private static func coffee(_ context: CGContext, colour: NSColor, level: Int) {
        let cup = CoffeeCup.forLevel(level)
        let body = CGRect(x: 3.5, y: 7.5, width: 9, height: 7)
        context.setLineWidth(1)
        context.setLineCap(.round)
        colour.setStroke()
        colour.setFill()

        // The cup: straight sides, a rounded bottom, open at the rim.
        let outline = CGMutablePath()
        outline.move(to: CGPoint(x: body.minX, y: body.minY))
        outline.addLine(to: CGPoint(x: body.minX, y: body.maxY - 2))
        outline.addQuadCurve(to: CGPoint(x: body.minX + 2, y: body.maxY),
                             control: CGPoint(x: body.minX, y: body.maxY))
        outline.addLine(to: CGPoint(x: body.maxX - 2, y: body.maxY))
        outline.addQuadCurve(to: CGPoint(x: body.maxX, y: body.maxY - 2),
                             control: CGPoint(x: body.maxX, y: body.maxY))
        outline.addLine(to: CGPoint(x: body.maxX, y: body.minY))
        context.addPath(outline)
        context.strokePath()
        context.strokeEllipse(in: CGRect(x: body.maxX - 0.5, y: body.minY + 1.5, width: 4, height: 4))
        line(context, from: CGPoint(x: 2, y: 16.5), to: CGPoint(x: 14, y: 16.5))

        // The coffee, from the bottom up to the level.
        let inside = body.insetBy(dx: 1.5, dy: 1.5)
        let liquid = inside.height * CGFloat(CoffeeCup.fill(forLevel: level))
        if liquid > 0 {
            context.fill(CGRect(x: inside.minX, y: inside.maxY - liquid, width: inside.width, height: liquid))
        }

        // Steam: wisps that wave as they rise.
        for wisp in 0..<cup.steamLines {
            let x = body.minX + 2 + CGFloat(wisp) * 2.5
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x, y: 6))
            path.addCurve(to: CGPoint(x: x, y: 1.5),
                          control1: CGPoint(x: x + 1.5, y: 4.5),
                          control2: CGPoint(x: x - 1.5, y: 3))
            context.addPath(path)
            context.strokePath()
        }

        // Full to the brim and beyond: the coffee stands over the rim and runs
        // down the far side from the handle.
        if cup.overflowing {
            context.fill(CGRect(x: body.minX - 0.5, y: body.minY - 1.5, width: body.width + 1, height: 2))
            context.fillEllipse(in: CGRect(x: body.minX - 2.5, y: body.minY + 1, width: 2, height: 2.5))
            context.fillEllipse(in: CGRect(x: body.minX - 2, y: body.minY + 4.5, width: 1.5, height: 2))
        }
    }
}

import AppKit
import SwiftUI

/// The Killdeer bird, the same artwork as the app icon.
///
/// Held as geometry rather than as a bundled image so the menu bar item stays
/// vector at every scale factor and the app needs no resource bundle. The
/// numbers are the glyph in `packaging/AppIcon.svg`; that file and this one are
/// the same drawing in two forms, so a change to one belongs in the other.
///
/// The parts overlap and are filled as a single path, which unions them under
/// the non-zero winding rule. That only holds while every subpath winds the
/// same way: mixed directions turn the overlaps into holes instead.
///
/// The eye is left out. The menu bar gives the icon about 18pt, where the eye
/// is a little over a point across and reads as a speck of noise rather than as
/// an eye.
struct KilldeerBird: Shape {
    /// The glyph in the icon's own coordinates, before it is fitted to a rect.
    private static func glyph() -> Path {
        var path = Path()

        path.move(to: CGPoint(x: 180.6, y: 309.9))
        path.addQuadCurve(to: CGPoint(x: 122.1, y: 245.3), control: CGPoint(x: 138.4, y: 309.3))
        path.addQuadCurve(to: CGPoint(x: 205.9, y: 221.5), control: CGPoint(x: 169.8, y: 199.7))
        path.closeSubpath()

        path.addEllipse(in: CGRect(x: 168, y: 212, width: 164, height: 140))
        path.addEllipse(in: CGRect(x: 264, y: 164, width: 88, height: 88))

        path.move(to: CGPoint(x: 339.5, y: 179.3))
        path.addLine(to: CGPoint(x: 401.1, y: 184.8))
        path.addLine(to: CGPoint(x: 349.2, y: 218.5))
        path.closeSubpath()

        path.addRoundedRect(in: CGRect(x: 221, y: 334, width: 12, height: 44),
                            cornerSize: CGSize(width: 6, height: 6))
        path.addRoundedRect(in: CGRect(x: 267, y: 334, width: 12, height: 44),
                            cornerSize: CGSize(width: 6, height: 6))

        return path
    }

    /// The glyph's bounding box, measured from the glyph rather than written
    /// out beside it. Written out, it would go stale the first time one of the
    /// coordinates above moved, and the bird would sit off-centre in its frame
    /// with nothing failing to say so.
    fileprivate static let design = glyph().boundingRect

    func path(in rect: CGRect) -> Path {
        let design = Self.design
        let scale = min(rect.width / design.width, rect.height / design.height)
        let width = design.width * scale, height = design.height * scale
        let fit = CGAffineTransform(translationX: rect.midX - width / 2, y: rect.midY - height / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -design.minX, y: -design.minY)
        return Self.glyph().applying(fit)
    }
}

extension KilldeerBird {
    /// The glyph as a menu bar image.
    ///
    /// An image rather than the `Shape` itself, because `MenuBarExtra` does not
    /// draw a bare `Shape` as its label: handed one, it produced a status item
    /// 18pt wide, which is the padding with nothing between it. The same glyph
    /// as an image gives a 41pt item, 23 of which is the bird.
    ///
    /// A template at that, rather than a fixed fill colour: the menu bar
    /// inverts a template on its own, both for dark mode and for the moment the
    /// menu is open. The warning image cannot be a template, because a template
    /// is painted in the system's colour and being red is the whole point.
    ///
    /// Drawn into a flipped context because `Shape.path(in:)` measures down
    /// from the top and an `NSImage` measures up from the bottom; without it
    /// the bird is upside down.
    ///
    /// With `meter`, a CPU meter stands beside the glyph: a thin upright gauge
    /// to the bird's right, filled from the bottom by `level` of `steps`.
    ///
    /// The gauge is drawn even when empty, so the status item keeps one width
    /// from launch onwards; a meter that appeared with the first CPU reading
    /// would nudge every item to its left a few seconds after login.
    ///
    /// It takes the same tint as the bird. The red still means "something is
    /// running away" and is still the only colour in the item; the meter says
    /// how busy the machine is, which is a different question and is answered
    /// by shape rather than colour.
    static func menuBarImage(
        tint: NSColor?,
        meter: (level: Int, steps: Int)? = nil,
        height: CGFloat = 18
    ) -> NSImage {
        let birdWidth = (height * design.width / design.height).rounded()
        let gap: CGFloat = meter == nil ? 0 : 2
        let meterWidth: CGFloat = meter == nil ? 0 : 5
        let size = NSSize(width: birdWidth + gap + meterWidth, height: height)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let colour = tint ?? .black
            context.addPath(KilldeerBird().path(in: CGRect(x: 0, y: 0, width: birdWidth, height: height)).cgPath)
            colour.setFill()
            context.fillPath()

            if let meter {
                // Inset vertically to roughly the bird's own height, so the
                // gauge does not stand taller than the glyph beside it.
                let frame = CGRect(x: birdWidth + gap, y: 2, width: meterWidth, height: height - 4)
                colour.setStroke()
                context.setLineWidth(1)
                // Stroked half a point inside so the 1pt line lands on whole
                // pixels at 1x instead of blurring across two.
                context.addPath(CGPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
                                       cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
                context.strokePath()

                let inner = frame.insetBy(dx: 1.5, dy: 1.5)
                let steps = max(1, meter.steps)
                let level = min(max(0, meter.level), steps)
                let filled = inner.height * CGFloat(level) / CGFloat(steps)
                // Flipped context: the bottom of the gauge is the largest y.
                context.fill(CGRect(x: inner.minX, y: inner.maxY - filled, width: inner.width, height: filled))
            }
            return true
        }
        image.isTemplate = tint == nil
        return image
    }
}

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
    static func menuBarImage(tint: NSColor?, height: CGFloat = 18) -> NSImage {
        let width = (height * design.width / design.height).rounded()
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(KilldeerBird().path(in: rect).cgPath)
            (tint ?? .black).setFill()
            context.fillPath()
            return true
        }
        image.isTemplate = tint == nil
        return image
    }
}

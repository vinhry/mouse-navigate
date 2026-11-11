import Foundation
@testable import MouseNavigateCore

/// How a person might draw each gesture, for generating test strokes.
///
/// These are written independently of `CharacterTemplates`, from how letters are commonly
/// handwritten, so that the evaluation does not simply ask the recognizer to find its own
/// templates again. They are still synthetic: smooth, idealised paths that a distortion model
/// then roughens. They are a model of hands, not hands.
///
/// Each gesture has the form the app's preview teaches ("taught") and, where people commonly
/// draw it some other way in one stroke, those forms too ("natural"): lower-case shapes, loops
/// started elsewhere or run the other way. A recognizer is not expected to accept every
/// natural form, but the more it does without accepting scribbles, the more forgiving it is.
struct ReferenceShape {
    enum Kind: String {
        case taught
        case natural
    }

    let gesture: CharacterGesture
    let name: String
    let kind: Kind
    let points: [Vector2]
    /// A closed loop, which a person may start anywhere round it.
    var isClosed = false
    /// Drawn backwards it is still unmistakably the same letter, and people do draw it so.
    var isReversible = false
}

extension PenPath {
    /// A path that begins on an arc, rather than moving to it.
    static func arc(_ cx: Double, _ cy: Double, rx: Double, ry: Double, from start: Double, to end: Double) -> PenPath {
        let radians = start * .pi / 180
        return PenPath(cx + rx * cos(radians), cy + ry * sin(radians))
            .arc(cx, cy, rx: rx, ry: ry, from: start, to: end)
    }
}

enum ReferenceShapes {
    static var all: [ReferenceShape] { letters + directions + strokes }

    // MARK: Letters

    private static func shape(
        _ gesture: CharacterGesture, _ name: String, _ kind: ReferenceShape.Kind, _ path: PenPath,
        closed: Bool = false, reversible: Bool = false
    ) -> ReferenceShape {
        ReferenceShape(gesture: gesture, name: name, kind: kind, points: path.points,
                       isClosed: closed, isReversible: reversible)
    }

    /// Upper bowl then lower bowl, from the top of a stem at x = 0.12, for B.
    private static func twoBowls(_ path: PenPath) -> PenPath {
        path.curve(0.78, 0.0, 0.76, 0.24).curve(0.74, 0.47, 0.18, 0.5)
            .curve(0.95, 0.52, 0.92, 0.76).curve(0.9, 1.0, 0.12, 0.98)
    }

    /// One bowl from the top of a stem down to its middle, for P and R.
    private static func upperBowl(_ path: PenPath) -> PenPath {
        path.curve(0.95, -0.04, 0.9, 0.27).curve(0.85, 0.56, 0.13, 0.53)
    }

    static let letters: [ReferenceShape] = [
        shape(.a, "peak", .taught, PenPath(0.08, 1).line(0.47, 0.02).line(0.93, 0.97)),
        shape(.a, "peak and crossbar", .natural,
              PenPath(0.06, 1).line(0.5, 0.01).line(0.94, 0.99).curve(0.8, 0.6, 0.5, 0.6).line(0.25, 0.62)),
        shape(.a, "lower-case bowl and stem", .natural,
              PenPath.arc(0.45, 0.55, rx: 0.37, ry: 0.42, from: -55, to: -380)
                  .line(0.84, 0.12).line(0.86, 0.9).curve(0.88, 1.0, 0.98, 0.95)),

        shape(.b, "stem up then bowls", .taught, twoBowls(PenPath(0.11, 1).line(0.12, 0))),
        shape(.b, "stem down, back up, then bowls", .natural,
              twoBowls(PenPath(0.12, 0).line(0.1, 1).line(0.12, 0.03))),
        shape(.b, "lower-case", .taught,
              PenPath(0.15, 0).line(0.13, 1).line(0.14, 0.55).curve(0.95, 0.35, 0.9, 0.78)
                  .curve(0.85, 1.02, 0.14, 0.95)),

        shape(.c, "round", .taught, PenPath.arc(0.55, 0.5, rx: 0.45, ry: 0.5, from: -40, to: -320), reversible: true),
        shape(.c, "tight", .natural, PenPath.arc(0.5, 0.5, rx: 0.4, ry: 0.5, from: -65, to: -295), reversible: true),

        shape(.d, "stem up then bowl", .taught,
              PenPath(0.12, 1).line(0.1, 0).curve(1.05, 0.0, 0.95, 0.5).curve(0.9, 1.02, 0.12, 0.98)),
        shape(.d, "stem down, back up, then bowl", .natural,
              PenPath(0.1, 0).line(0.12, 1).line(0.1, 0.03).curve(1.0, 0.0, 0.95, 0.5).curve(0.9, 1.0, 0.1, 0.97)),
        shape(.d, "lower-case stem first", .taught,
              PenPath(0.85, 0).line(0.86, 1).line(0.86, 0.62).curve(0.1, 0.3, 0.12, 0.8).curve(0.2, 1.05, 0.86, 0.86)),
        shape(.d, "lower-case bowl first", .natural,
              PenPath.arc(0.45, 0.73, rx: 0.3, ry: 0.26, from: -35, to: -385).line(0.76, 0).line(0.78, 1)),

        shape(.e, "reversed three", .taught,
              PenPath(0.9, 0.08).curve(0.1, -0.08, 0.15, 0.25).curve(0.2, 0.48, 0.55, 0.5)
                  .curve(0.05, 0.52, 0.08, 0.78).curve(0.15, 1.06, 0.92, 0.92)),
        shape(.e, "lower-case loop", .natural,
              PenPath(0.1, 0.52).line(0.88, 0.5).arc(0.5, 0.52, rx: 0.4, ry: 0.46, from: -2, to: -320)),

        shape(.f, "bar then stem", .taught, PenPath(0.92, 0.03).line(0.08, 0).line(0.1, 1)),
        shape(.f, "hooked top", .natural,
              PenPath(0.95, 0.12).curve(0.6, -0.05, 0.3, 0.05).curve(0.12, 0.12, 0.15, 0.4).line(0.15, 1)),

        shape(.g, "C then inward bar", .taught,
              PenPath.arc(0.5, 0.5, rx: 0.45, ry: 0.5, from: -35, to: -350).line(0.96, 0.55).line(0.55, 0.56)),
        shape(.g, "C, up, then bar", .natural,
              PenPath.arc(0.5, 0.5, rx: 0.45, ry: 0.5, from: -40, to: -330).line(0.92, 0.5).line(0.6, 0.5)),

        shape(.h, "stem then arch off the stem", .taught,
              PenPath(0.12, 0).line(0.1, 1).line(0.11, 0.6).curve(0.5, 0.25, 0.88, 0.55).line(0.9, 1)),
        shape(.h, "stem then arch from the foot", .natural,
              PenPath(0.12, 0).line(0.1, 1).curve(0.2, 0.4, 0.6, 0.42).curve(0.92, 0.45, 0.9, 1)),

        shape(.j, "hook", .taught,
              PenPath(0.78, 0).line(0.8, 0.72).curve(0.8, 1.02, 0.45, 1.0).curve(0.15, 0.98, 0.1, 0.75)),
        shape(.j, "corner", .natural, PenPath(0.85, 0).line(0.86, 0.98).line(0.1, 1.0)),

        shape(.k, "angle", .taught, PenPath(0.9, 0).line(0.12, 0.5).line(0.92, 1)),
        shape(.k, "stem then angle", .natural,
              PenPath(0.15, 0).line(0.15, 1).line(0.15, 0.55).line(0.85, 0.02).line(0.2, 0.55).line(0.9, 1)),

        shape(.l, "corner", .taught, PenPath(0.1, 0).line(0.12, 1).line(0.85, 0.98)),
        shape(.l, "short foot", .natural, PenPath(0.1, 0).line(0.1, 1).line(0.45, 1)),
        shape(.l, "rounded", .natural, PenPath(0.1, 0).line(0.1, 0.85).curve(0.1, 1, 0.3, 1).line(0.85, 1)),

        shape(.m, "peaks", .taught,
              PenPath(0.05, 1).line(0.12, 0).line(0.5, 0.62).line(0.88, 0.02).line(0.95, 1)),
        shape(.m, "lower-case arches", .natural,
              PenPath(0.08, 0.3).line(0.08, 1).line(0.09, 0.5).curve(0.28, 0.15, 0.48, 0.5).line(0.5, 1)
                  .line(0.51, 0.5).curve(0.72, 0.15, 0.92, 0.5).line(0.93, 1)),

        shape(.n, "zigzag", .taught, PenPath(0.1, 1).line(0.1, 0).line(0.9, 1).line(0.9, 0)),
        shape(.n, "lower-case arch", .natural,
              PenPath(0.12, 0.1).line(0.12, 1).line(0.13, 0.4).curve(0.5, -0.1, 0.88, 0.35).line(0.9, 1)),

        shape(.o, "anticlockwise from the top", .taught,
              PenPath.arc(0.5, 0.5, rx: 0.45, ry: 0.5, from: -90, to: -450), closed: true, reversible: true),
        shape(.o, "clockwise from the top", .natural,
              PenPath.arc(0.5, 0.5, rx: 0.45, ry: 0.5, from: -90, to: 270), closed: true, reversible: true),
        shape(.o, "anticlockwise from upper right, overlapping", .natural,
              PenPath.arc(0.5, 0.5, rx: 0.42, ry: 0.5, from: -45, to: -425), closed: true, reversible: true),

        shape(.p, "stem up then bowl", .taught, upperBowl(PenPath(0.12, 1).line(0.1, 0))),
        shape(.p, "stem down, back up, then bowl", .natural, upperBowl(PenPath(0.1, 0).line(0.12, 1).line(0.11, 0.02))),

        shape(.q, "O with a tail", .taught,
              PenPath.arc(0.48, 0.48, rx: 0.43, ry: 0.45, from: 50, to: -300).line(1.0, 1.0)),
        shape(.q, "lower-case bowl and descender", .natural,
              PenPath.arc(0.45, 0.33, rx: 0.33, ry: 0.31, from: -20, to: -375).line(0.8, 1.0).line(0.95, 0.88)),

        shape(.r, "stem up, bowl, leg", .taught, upperBowl(PenPath(0.12, 1).line(0.1, 0)).line(0.9, 1)),
        shape(.r, "stem down, back up, bowl, leg", .natural,
              upperBowl(PenPath(0.1, 0).line(0.12, 1).line(0.11, 0.02)).line(0.9, 1)),

        shape(.s, "from the top", .taught,
              PenPath(0.88, 0.12).curve(0.5, -0.1, 0.2, 0.1).curve(0.0, 0.35, 0.5, 0.5)
                  .curve(1.0, 0.65, 0.8, 0.9).curve(0.5, 1.1, 0.1, 0.88), reversible: true),
        shape(.s, "narrow", .natural,
              PenPath(0.8, 0.05).curve(0.2, -0.05, 0.25, 0.25).curve(0.3, 0.45, 0.55, 0.52)
                  .curve(0.85, 0.62, 0.75, 0.85).curve(0.6, 1.05, 0.2, 0.95), reversible: true),

        shape(.t, "right then down", .taught, PenPath(0.05, 0.02).line(0.92, 0).line(0.9, 1)),
        shape(.t, "bar, back to the middle, down", .taught,
              PenPath(0.05, 0.03).line(0.95, 0).line(0.5, 0.02).line(0.52, 1)),

        shape(.u, "round", .taught,
              PenPath(0.1, 0).line(0.1, 0.65).curve(0.12, 1.02, 0.5, 1.0).curve(0.88, 1.0, 0.9, 0.65).line(0.9, 0),
              reversible: true),
        shape(.u, "lower-case with a tail", .natural,
              PenPath(0.1, 0).line(0.1, 0.6).curve(0.12, 1.0, 0.5, 1.0).curve(0.85, 0.98, 0.88, 0.6)
                  .line(0.88, 0).line(0.9, 1)),

        shape(.v, "sharp", .taught, PenPath(0.05, 0).line(0.5, 1).line(0.95, 0), reversible: true),
        shape(.v, "rounded", .natural,
              PenPath(0.05, 0).line(0.42, 0.9).curve(0.5, 1.05, 0.58, 0.9).line(0.95, 0), reversible: true),

        shape(.w, "sharp", .taught,
              PenPath(0.02, 0).line(0.25, 1).line(0.5, 0.35).line(0.75, 1).line(0.98, 0), reversible: true),
        shape(.w, "rounded", .natural,
              PenPath(0.02, 0.05).curve(0.1, 1.0, 0.27, 0.98).curve(0.45, 0.95, 0.5, 0.3)
                  .curve(0.55, 0.95, 0.73, 0.98).curve(0.9, 1.0, 0.98, 0.05), reversible: true),

        shape(.x, "diagonal, across, diagonal", .taught,
              PenPath(0.05, 0).line(0.95, 1).line(0.05, 1).line(0.95, 0)),
        shape(.x, "rounded turn", .natural,
              PenPath(0.05, 0).line(0.88, 0.92).curve(0.5, 1.15, 0.1, 0.92).line(0.95, 0)),

        shape(.y, "V then descender", .taught, PenPath(0.05, 0).line(0.5, 0.5).line(0.95, 0).line(0.3, 1)),
        shape(.y, "lower-case u then descender", .natural,
              PenPath(0.1, 0).curve(0.1, 0.5, 0.45, 0.48).curve(0.85, 0.45, 0.85, 0).line(0.8, 0.85)
                  .curve(0.6, 1.1, 0.2, 0.9)),

        shape(.z, "sharp", .taught, PenPath(0.05, 0).line(0.95, 0.02).line(0.05, 1).line(0.95, 0.98)),
        shape(.z, "curved top", .natural,
              PenPath(0.05, 0.1).curve(0.5, -0.1, 0.92, 0.05).line(0.08, 1).line(0.95, 0.95)),
    ]

    // MARK: Directions

    /// A unit line pointing the way of each direction, before any slant is added.
    static let directions: [ReferenceShape] = CharacterGesture.directions.map { gesture in
        let angle = directionAngle(gesture)
        let d = Vector2(x: cos(angle), y: sin(angle)) * 0.5
        let centre = Vector2(x: 0.5, y: 0.5)
        return ReferenceShape(gesture: gesture, name: "line", kind: .taught, points: [centre - d, centre + d])
    }

    /// Radians, +y down: right is 0 and down is a quarter turn.
    static func directionAngle(_ gesture: CharacterGesture) -> Double {
        let order: [CharacterGesture] = [.right, .downRight, .down, .downLeft, .left, .upLeft, .up, .upRight]
        return Double(order.firstIndex(of: gesture)!) * .pi / 4
    }

    // MARK: Corner and out-and-back strokes

    private static func unit(_ gesture: CharacterGesture) -> Vector2 {
        let angle = directionAngle(gesture)
        return Vector2(x: cos(angle).rounded(), y: sin(angle).rounded())
    }

    /// The four corners that are not letters, and the four out-and-back strokes, each with
    /// a second leg as long as the first and shorter ones, since a hand seldom matches them.
    static let strokes: [ReferenceShape] = {
        let corners: [(CharacterGesture, CharacterGesture, CharacterGesture)] = [
            (.leftThenUp, .left, .up), (.rightThenUp, .right, .up),
            (.upThenLeft, .up, .left), (.upThenRight, .up, .right),
        ]
        let returns: [(CharacterGesture, CharacterGesture)] = [
            (.leftThenRight, .left), (.rightThenLeft, .right), (.upThenDown, .up), (.downThenUp, .down),
        ]
        var shapes: [ReferenceShape] = []
        for (gesture, first, second) in corners {
            for ratio in [1.0, 0.6, 0.35] {
                let a = unit(first)
                let b = unit(second)
                let points = [Vector2.zero, a, a + b * ratio]
                shapes.append(ReferenceShape(gesture: gesture, name: "legs 1:\(ratio)",
                                             kind: ratio == 1 ? .taught : .natural, points: points))
            }
        }
        for (gesture, out) in returns {
            for ratio in [1.0, 0.7, 0.45] {
                let a = unit(out)
                // Coming back a little beside the outward leg, as a hand does.
                let beside = Vector2(x: -a.y, y: a.x) * 0.06
                let points = [Vector2.zero, a, a - a * ratio + beside]
                shapes.append(ReferenceShape(gesture: gesture, name: "return \(ratio)",
                                             kind: ratio == 1 ? .taught : .natural, points: points))
            }
        }
        return shapes
    }()
}

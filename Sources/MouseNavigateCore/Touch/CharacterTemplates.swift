import Foundation

/// A reference drawing of one character.
public struct CharacterTemplate {
    public let gesture: CharacterGesture
    public let points: [Vector2]

    init(_ gesture: CharacterGesture, _ points: [(Double, Double)]) {
        self.gesture = gesture
        self.points = points.map { Vector2(x: $0.0, y: $0.1) }
    }
}

/// Single-stroke letter shapes, loosely after Graffiti, drawn in a unit box with +y down.
/// Each is traced in the direction people naturally write it, because the matcher is
/// direction-sensitive. `I` has no template: it is a straight downward stroke.
public enum CharacterTemplates {
    public static let all: [CharacterTemplate] = [
        CharacterTemplate(.a, [(0, 1), (0.5, 0), (1, 1)]),
        CharacterTemplate(.a, [(0, 1), (0.5, 0), (1, 1), (0.75, 0.55), (0.25, 0.55)]),

        CharacterTemplate(.b, [(0, 1), (0, 0), (0.6, 0), (0.9, 0.12), (0.9, 0.38), (0.55, 0.5),
                               (0.95, 0.62), (0.95, 0.88), (0.6, 1), (0, 1)]),
        CharacterTemplate(.b, [(0, 0), (0, 1), (0, 0.5), (0.6, 0.5), (0.95, 0.62), (0.95, 0.88),
                               (0.6, 1), (0, 1)]),

        CharacterTemplate(.c, arc(from: -45, to: -315)),

        CharacterTemplate(.d, [(0, 1), (0, 0), (0.5, 0), (0.9, 0.2), (1, 0.5), (0.9, 0.8),
                               (0.5, 1), (0, 1)]),
        CharacterTemplate(.d, [(1, 0), (1, 1), (1, 0.6), (0.6, 0.45), (0.15, 0.55), (0, 0.8),
                               (0.2, 1), (0.6, 1), (1, 0.85)]),

        CharacterTemplate(.e, [(1, 0.05), (0.5, 0), (0.1, 0.12), (0.1, 0.38), (0.5, 0.5),
                               (0.05, 0.62), (0.05, 0.88), (0.5, 1), (1, 0.95)]),

        CharacterTemplate(.f, [(1, 0), (0, 0), (0, 1)]),

        CharacterTemplate(.g, arc(from: -45, to: -360) + [(1, 0.55), (0.55, 0.55)].map { Vector2(x: $0.0, y: $0.1) }),

        CharacterTemplate(.h, [(0, 0), (0, 1), (0.1, 0.6), (0.5, 0.45), (0.9, 0.6), (1, 1)]),

        CharacterTemplate(.j, [(1, 0), (1, 0.75), (0.8, 1), (0.4, 1), (0.1, 0.8)]),

        CharacterTemplate(.k, [(1, 0), (0, 0.5), (1, 1)]),

        CharacterTemplate(.l, [(0, 0), (0, 1), (0.8, 1)]),

        CharacterTemplate(.m, [(0, 1), (0, 0), (0.5, 0.6), (1, 0), (1, 1)]),

        CharacterTemplate(.n, [(0, 1), (0, 0), (1, 1), (1, 0)]),

        CharacterTemplate(.o, arc(from: -90, to: -450)),
        CharacterTemplate(.o, arc(from: -90, to: 270)),

        CharacterTemplate(.p, [(0, 1), (0, 0), (0.6, 0), (0.95, 0.15), (0.95, 0.4), (0.6, 0.55),
                               (0, 0.55)]),

        CharacterTemplate(.q, arc(from: 45, to: -315) + [(1.1, 1.1)].map { Vector2(x: $0.0, y: $0.1) }),

        CharacterTemplate(.r, [(0, 1), (0, 0), (0.6, 0), (0.95, 0.15), (0.95, 0.4), (0.6, 0.55),
                               (0, 0.55), (1, 1)]),

        CharacterTemplate(.s, [(1, 0.1), (0.7, 0), (0.2, 0), (0, 0.2), (0.2, 0.45), (0.8, 0.55),
                               (1, 0.8), (0.8, 1), (0.3, 1), (0, 0.9)]),

        CharacterTemplate(.t, [(0, 0), (1, 0), (1, 1)]),
        CharacterTemplate(.t, [(0, 0), (1, 0), (0.5, 0), (0.5, 1)]),

        CharacterTemplate(.u, [(0, 0), (0, 0.7), (0.2, 1), (0.8, 1), (1, 0.7), (1, 0)]),

        CharacterTemplate(.v, [(0, 0), (0.5, 1), (1, 0)]),

        CharacterTemplate(.w, [(0, 0), (0.25, 1), (0.5, 0.4), (0.75, 1), (1, 0)]),

        CharacterTemplate(.x, [(0, 0), (1, 1), (0, 1), (1, 0)]),

        CharacterTemplate(.y, [(0, 0), (0.5, 0.5), (1, 0), (0.3, 1)]),

        CharacterTemplate(.z, [(0, 0), (1, 0), (0, 1), (1, 1)]),
    ]

    /// The stroke to show someone who wants to know how a character is drawn: the shape the
    /// recogniser matches, in the order it expects. Directions have no template, since a
    /// straight stroke is recognised by being straight, so they are drawn across the box.
    public static func preview(for gesture: CharacterGesture) -> [Vector2] {
        if let template = all.first(where: { $0.gesture == gesture }) {
            return template.points
        }

        let (dx, dy): (Double, Double)
        switch gesture {
        case .up: (dx, dy) = (0, -1)
        case .down: (dx, dy) = (0, 1)
        case .left: (dx, dy) = (-1, 0)
        case .right: (dx, dy) = (1, 0)
        case .upLeft: (dx, dy) = (-1, -1)
        case .upRight: (dx, dy) = (1, -1)
        case .downLeft: (dx, dy) = (-1, 1)
        case .downRight: (dx, dy) = (1, 1)
        default: return []
        }
        return [
            Vector2(x: 0.5 - dx * 0.4, y: 0.5 - dy * 0.4),
            Vector2(x: 0.5 + dx * 0.4, y: 0.5 + dy * 0.4),
        ]
    }

    /// Points round an ellipse filling the unit box. Angles in degrees, 0 pointing right and
    /// increasing clockwise on screen, since +y is down.
    static func arc(from start: Double, to end: Double, steps: Int = 24) -> [Vector2] {
        (0...steps).map { step in
            let degrees = start + (end - start) * Double(step) / Double(steps)
            let radians = degrees * .pi / 180
            return Vector2(x: 0.5 + 0.5 * cos(radians), y: 0.5 + 0.5 * sin(radians))
        }
    }
}

extension CharacterTemplate {
    init(_ gesture: CharacterGesture, _ points: [Vector2]) {
        self.gesture = gesture
        self.points = points
    }
}

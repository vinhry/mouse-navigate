import Foundation
@testable import MouseNavigateCore

// The recognizer and templates as they were in 0.8.1, frozen here so the evaluation can
// always report how the current recognizer compares with the one people were using.
// Not used by the app.

/// The 0.8.1 recognizer: a straight-line gate, then $1 unistroke matching without rotation
/// invariance against one or two templates per gesture.
struct LegacyStrokeRecognizer {
    typealias Match = StrokeRecognizer.Match

    /// Endpoint distance over path length at which a stroke counts as a straight line.
    var straightness = 0.9
    /// Below this a letter match is rejected as a scribble.
    var minimumScore = 0.8

    private static let sampleCount = 64
    private static let rotationLimit = 15 * Double.pi / 180
    private static let rotationPrecision = 2 * Double.pi / 180
    private static let halfDiagonal = 0.5 * 2.0.squareRoot()

    private let templates: [(gesture: CharacterGesture, points: [Vector2])]

    init(templates: [CharacterTemplate] = LegacyTemplates.all) {
        self.templates = templates.map { ($0.gesture, LegacyStrokeRecognizer.normalize($0.points)) }
    }

    func recognize(_ points: [Vector2]) -> CharacterGesture? {
        guard let match = bestMatch(points), accepts(match) else { return nil }
        return match.gesture
    }

    /// Whether a match is close enough to be the letter, rather than a scribble that
    /// happened to be nearest it. Lets a caller that already has the match avoid a second
    /// search.
    func accepts(_ match: Match) -> Bool {
        match.score >= minimumScore
    }

    /// The closest gesture whatever its score, for diagnostics.
    func bestMatch(_ points: [Vector2]) -> Match? {
        let length = LegacyStrokeRecognizer.pathLength(points)
        guard points.count >= 2, length > 0 else { return nil }

        let first = points[0]
        let last = points[points.count - 1]
        let span = Vector2(x: last.x - first.x, y: last.y - first.y)
        if span.magnitude / length >= straightness {
            return Match(gesture: LegacyStrokeRecognizer.direction(of: span), score: 1)
        }

        let candidate = LegacyStrokeRecognizer.normalize(points)
        var best: Match?
        for template in templates {
            let distance = LegacyStrokeRecognizer.distanceAtBestAngle(candidate, template.points)
            let score = 1 - distance / LegacyStrokeRecognizer.halfDiagonal
            if score > best?.score ?? -.infinity {
                best = Match(gesture: template.gesture, score: score)
            }
        }
        return best
    }

    // MARK: - Directions

    /// Eight 45° sectors centred on the compass directions, with +y down.
    static func direction(of vector: Vector2) -> CharacterGesture {
        let degrees = atan2(vector.y, vector.x) * 180 / .pi
        let sector = Int(((degrees + 360 + 22.5).truncatingRemainder(dividingBy: 360)) / 45)
        let order: [CharacterGesture] = [.right, .downRight, .down, .downLeft, .left, .upLeft, .up, .upRight]
        return order[sector % 8]
    }

    // MARK: - $1 steps

    static func normalize(_ points: [Vector2]) -> [Vector2] {
        translateToOrigin(scaleToUnit(resample(points, count: sampleCount)))
    }

    static func resample(_ points: [Vector2], count: Int) -> [Vector2] {
        let interval = pathLength(points) / Double(count - 1)
        guard interval > 0, var previous = points.first else {
            return Array(repeating: points.first ?? .zero, count: count)
        }

        var result = [previous]
        var carried = 0.0
        var index = 1
        while index < points.count {
            let current = points[index]
            let segment = Vector2(x: current.x - previous.x, y: current.y - previous.y).magnitude
            if carried + segment >= interval, segment > 0 {
                let t = (interval - carried) / segment
                let point = Vector2(
                    x: previous.x + t * (current.x - previous.x),
                    y: previous.y + t * (current.y - previous.y)
                )
                result.append(point)
                previous = point
                carried = 0
            } else {
                carried += segment
                previous = current
                index += 1
            }
        }
        // Floating-point error can leave the last point off the end.
        while result.count < count {
            result.append(points[points.count - 1])
        }
        return Array(result.prefix(count))
    }

    /// Uniform scaling keeps a tall narrow letter tall and narrow.
    static func scaleToUnit(_ points: [Vector2]) -> [Vector2] {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let width = (xs.max() ?? 0) - (xs.min() ?? 0)
        let height = (ys.max() ?? 0) - (ys.min() ?? 0)
        let size = max(width, height)
        guard size > 0 else { return points }
        return points.map { Vector2(x: $0.x / size, y: $0.y / size) }
    }

    static func translateToOrigin(_ points: [Vector2]) -> [Vector2] {
        let centroid = Vector2(
            x: points.map(\.x).reduce(0, +) / Double(points.count),
            y: points.map(\.y).reduce(0, +) / Double(points.count)
        )
        return points.map { Vector2(x: $0.x - centroid.x, y: $0.y - centroid.y) }
    }

    /// Golden-section search for the small rotation that best lines the stroke up with the
    /// template, which forgives a slightly slanted hand.
    static func distanceAtBestAngle(_ points: [Vector2], _ template: [Vector2]) -> Double {
        let phi = 0.5 * (-1 + 5.0.squareRoot())
        var low = -rotationLimit
        var high = rotationLimit
        var x1 = phi * low + (1 - phi) * high
        var f1 = distance(rotate(points, by: x1), template)
        var x2 = (1 - phi) * low + phi * high
        var f2 = distance(rotate(points, by: x2), template)

        while abs(high - low) > rotationPrecision {
            if f1 < f2 {
                high = x2
                x2 = x1
                f2 = f1
                x1 = phi * low + (1 - phi) * high
                f1 = distance(rotate(points, by: x1), template)
            } else {
                low = x1
                x1 = x2
                f1 = f2
                x2 = (1 - phi) * low + phi * high
                f2 = distance(rotate(points, by: x2), template)
            }
        }
        return min(f1, f2)
    }

    static func rotate(_ points: [Vector2], by radians: Double) -> [Vector2] {
        let cosine = cos(radians)
        let sine = sin(radians)
        return points.map { Vector2(x: $0.x * cosine - $0.y * sine, y: $0.x * sine + $0.y * cosine) }
    }

    static func distance(_ a: [Vector2], _ b: [Vector2]) -> Double {
        let total = zip(a, b).reduce(0) { sum, pair in
            sum + Vector2(x: pair.0.x - pair.1.x, y: pair.0.y - pair.1.y).magnitude
        }
        return total / Double(min(a.count, b.count))
    }

    static func pathLength(_ points: [Vector2]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { total, pair in
            total + Vector2(x: pair.1.x - pair.0.x, y: pair.1.y - pair.0.y).magnitude
        }
    }
}

/// Single-stroke letter shapes, loosely after Graffiti, drawn in a unit box with +y down,
/// then the corner and out-and-back strokes. Each is traced in the direction people
/// naturally write it, because the matcher is direction-sensitive. `I` has no template: it
/// is a straight downward stroke.
enum LegacyTemplates {
    static let all: [CharacterTemplate] = letters + strokes

    /// Each comes in two: legs the same length, and a second leg half as long, since the
    /// matcher keeps a stroke's proportions and a short second leg would otherwise sit far
    /// from the template. An out-and-back stroke returns a little beside its outward leg,
    /// so its preview reads as two lines rather than one drawn over itself.
    static let strokes: [CharacterTemplate] = [
        CharacterTemplate(.leftThenUp, [(1, 1), (0, 1), (0, 0)]),
        CharacterTemplate(.leftThenUp, [(1, 0.5), (0, 0.5), (0, 0)]),
        CharacterTemplate(.rightThenUp, [(0, 1), (1, 1), (1, 0)]),
        CharacterTemplate(.rightThenUp, [(0, 0.5), (1, 0.5), (1, 0)]),
        CharacterTemplate(.upThenLeft, [(1, 1), (1, 0), (0, 0)]),
        CharacterTemplate(.upThenLeft, [(0.5, 1), (0.5, 0), (0, 0)]),
        CharacterTemplate(.upThenRight, [(0, 1), (0, 0), (1, 0)]),
        CharacterTemplate(.upThenRight, [(0.5, 1), (0.5, 0), (1, 0)]),

        CharacterTemplate(.leftThenRight, [(1, 0.45), (0, 0.5), (1, 0.55)]),
        CharacterTemplate(.leftThenRight, [(1, 0.45), (0, 0.5), (0.5, 0.55)]),
        CharacterTemplate(.rightThenLeft, [(0, 0.45), (1, 0.5), (0, 0.55)]),
        CharacterTemplate(.rightThenLeft, [(0, 0.45), (1, 0.5), (0.5, 0.55)]),
        CharacterTemplate(.upThenDown, [(0.45, 1), (0.5, 0), (0.55, 1)]),
        CharacterTemplate(.upThenDown, [(0.45, 1), (0.5, 0), (0.55, 0.5)]),
        CharacterTemplate(.downThenUp, [(0.45, 0), (0.5, 1), (0.55, 0)]),
        CharacterTemplate(.downThenUp, [(0.45, 0), (0.5, 1), (0.55, 0.5)]),
    ]

    static let letters: [CharacterTemplate] = [
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

    static func arc(from start: Double, to end: Double, steps: Int = 24) -> [Vector2] {
        CharacterTemplates.arc(from: start, to: end, steps: steps)
    }
}

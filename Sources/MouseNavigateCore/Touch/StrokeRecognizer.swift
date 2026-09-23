import Foundation

/// A drawn letter or straight-line direction that can be bound to an action.
public enum CharacterGesture: String, CaseIterable {
    case a, b, c, d, e, f, g, h, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z
    case up, down, left, right, upLeft, upRight, downLeft, downRight

    public var displayName: String {
        switch self {
        case .up: return "Up ↑"
        case .down: return "Down ↓ (I)"
        case .left: return "Left ←"
        case .right: return "Right →"
        case .upLeft: return "Up-Left ↖"
        case .upRight: return "Up-Right ↗"
        case .downLeft: return "Down-Left ↙"
        case .downRight: return "Down-Right ↘"
        default: return rawValue.uppercased()
        }
    }

    public var isDirection: Bool {
        CharacterGesture.directions.contains(self)
    }

    public static let directions: [CharacterGesture] = [
        .up, .down, .left, .right, .upLeft, .upRight, .downLeft, .downRight,
    ]

    public var defaultAction: ButtonAction {
        switch self {
        case .b: return .launchBrowser
        case .f: return .launchFinder
        case .n: return .newDocument
        case .o: return .open
        case .s: return .save
        case .t: return .newTab
        case .down: return .paste
        case .up: return .copy
        case .left: return .maximizeLeft
        case .right: return .maximizeRight
        default: return .disabled
        }
    }
}

/// Recognizes a drawn stroke. Nearly straight strokes are read as one of eight directions;
/// anything else is compared with the letter templates using the $1 unistroke method
/// (Wobbrock, Wilson and Li, 2007), minus its rotation invariance, since orientation is what
/// tells many letters apart.
public struct StrokeRecognizer {
    public struct Match: Equatable {
        public let gesture: CharacterGesture
        /// 1 is a perfect match.
        public let score: Double
    }

    /// Endpoint distance over path length at which a stroke counts as a straight line.
    public var straightness = 0.9
    /// Below this a letter match is rejected as a scribble.
    public var minimumScore = 0.8

    private static let sampleCount = 64
    private static let rotationLimit = 15 * Double.pi / 180
    private static let rotationPrecision = 2 * Double.pi / 180
    private static let halfDiagonal = 0.5 * 2.0.squareRoot()

    private let templates: [(gesture: CharacterGesture, points: [Vector2])]

    public init(templates: [CharacterTemplate] = CharacterTemplates.all) {
        self.templates = templates.map { ($0.gesture, StrokeRecognizer.normalize($0.points)) }
    }

    public func recognize(_ points: [Vector2]) -> CharacterGesture? {
        guard let match = bestMatch(points), match.score >= minimumScore else { return nil }
        return match.gesture
    }

    /// The closest gesture whatever its score, for diagnostics.
    public func bestMatch(_ points: [Vector2]) -> Match? {
        let length = StrokeRecognizer.pathLength(points)
        guard points.count >= 2, length > 0 else { return nil }

        let first = points[0]
        let last = points[points.count - 1]
        let span = Vector2(x: last.x - first.x, y: last.y - first.y)
        if span.magnitude / length >= straightness {
            return Match(gesture: StrokeRecognizer.direction(of: span), score: 1)
        }

        let candidate = StrokeRecognizer.normalize(points)
        var best: Match?
        for template in templates {
            let distance = StrokeRecognizer.distanceAtBestAngle(candidate, template.points)
            let score = 1 - distance / StrokeRecognizer.halfDiagonal
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

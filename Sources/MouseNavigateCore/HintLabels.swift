import Foundation

/// Labels for clickable things on screen, typed to pick one.
///
/// Every label has the same length, the shortest that gives each target its own: with 24
/// letters that is one keystroke for up to 24 targets and two for up to 576. Equal lengths
/// mean no label is the start of another, so a match is final the moment it is typed.
public enum HintLabels {
    /// Easiest to reach first: the home row, then the rows above and below it.
    public static let preferredKeys: [UInt16] = [
        KeyCode.s, KeyCode.d, KeyCode.f, KeyCode.j, KeyCode.k, KeyCode.l, KeyCode.g, KeyCode.h,
        KeyCode.e, KeyCode.r, KeyCode.u, KeyCode.i, KeyCode.w, KeyCode.o, KeyCode.c, KeyCode.m,
        KeyCode.v, KeyCode.n, KeyCode.t, KeyCode.y, KeyCode.q, KeyCode.p, KeyCode.x, KeyCode.b,
        KeyCode.z, KeyCode.a,
    ]

    /// The letters labels are made of. The activation key is left out: it is usually still
    /// held down while the hints are up, so it could never be typed as part of one.
    public static func alphabet(excluding excluded: Set<UInt16>) -> [UInt16] {
        preferredKeys.filter { !excluded.contains($0) }
    }

    public static func generate(count: Int, alphabet: [UInt16]) -> [[UInt16]] {
        guard count > 0, alphabet.count > 1 else {
            return count == 1 && !alphabet.isEmpty ? [[alphabet[0]]] : []
        }

        var length = 1
        var capacity = alphabet.count
        while capacity < count {
            length += 1
            capacity *= alphabet.count
        }

        return (0..<count).map { index in
            var label: [UInt16] = []
            var remainder = index
            for _ in 0..<length {
                label.append(alphabet[remainder % alphabet.count])
                remainder /= alphabet.count
            }
            // Most significant key first, so neighbouring targets share a first letter
            // and the easiest keys lead.
            return label.reversed()
        }
    }
}

/// Narrows a set of labels as keys are typed.
public struct HintFilter {
    public enum Result: Equatable {
        /// Still more than one label fits what has been typed.
        case narrowed
        /// Exactly one label was typed in full: its index.
        case matched(Int)
        /// The key fits no label and was ignored.
        case rejected
    }

    public let labels: [[UInt16]]
    public private(set) var typed: [UInt16] = []

    public init(labels: [[UInt16]]) {
        self.labels = labels
    }

    public func isVisible(_ index: Int) -> Bool {
        labels[index].starts(with: typed)
    }

    public mutating func type(_ keyCode: UInt16) -> Result {
        let candidate = typed + [keyCode]
        let matches = labels.indices.filter { labels[$0].starts(with: candidate) }
        guard !matches.isEmpty else { return .rejected }

        typed = candidate
        if matches.count == 1, labels[matches[0]].count == candidate.count {
            return .matched(matches[0])
        }
        return .narrowed
    }

    /// Returns false when nothing had been typed.
    @discardableResult
    public mutating func deleteLast() -> Bool {
        typed.popLast() != nil
    }
}

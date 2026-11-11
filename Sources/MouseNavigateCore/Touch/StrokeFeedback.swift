import Foundation

/// What to tell someone who has just drawn something: the two lines the overlay shows.
public struct StrokeFeedback: Equatable, Sendable {
    public let title: String
    public let subtitle: String?

    /// How far below `minimumScore` a rejected drawing may fall and still be told what it was
    /// closest to. Scores are stretched so that the default minimum sits at 0.8 and a perfect
    /// match at 1, so 0.15 reaches down to about 0.65 by default: a drawing that was nearly a
    /// letter, but not a scribble, which is nearly nothing. It moves with the Letter matching
    /// slider, so a looser setting names closer misses only.
    public static let closestLetterReach = 0.15

    /// A runner-up this near the best, or nearer, is named too: the drawing could as well
    /// have been either.
    public static let tieMargin = 0.04

    /// `actionName` is what the drawing's letter runs, or nil when nothing is bound to it.
    /// A drawing is rejected exactly when `StrokeRecognizer.accepts` says so.
    public static func lines(for match: StrokeRecognizer.Match?, minimumScore: Double, actionName: String?) -> StrokeFeedback {
        guard let match else { return StrokeFeedback(title: "no match", subtitle: nil) }

        if match.score >= minimumScore {
            return StrokeFeedback(title: match.gesture.displayName, subtitle: actionName ?? "No action")
        }

        let floor = minimumScore - closestLetterReach
        guard match.score >= floor else { return StrokeFeedback(title: "no match", subtitle: nil) }

        var closest = match.gesture.displayName
        if let other = match.runnerUp, let otherScore = match.runnerUpScore,
           otherScore >= floor, match.score - otherScore <= tieMargin {
            closest += " or \(other.displayName)"
        }
        return StrokeFeedback(title: "no match", subtitle: "Closest: \(closest)")
    }
}

extension StrokeFeedback {
    /// The line the touch debug log prints for a drawing: the best match, the runner-up and
    /// what the match needed, e.g. "B (score 0.84), then D (0.79), needs 0.80". Scores only,
    /// nothing of the stroke's shape.
    public static func debugDescription(of match: StrokeRecognizer.Match?, minimumScore: Double) -> String {
        guard let match else { return "nothing" }
        var text = "\(match.gesture.displayName) (score \(String(format: "%.2f", match.score)))"
        if let other = match.runnerUp, let score = match.runnerUpScore {
            text += ", then \(other.displayName) (\(String(format: "%.2f", score)))"
        }
        return text + ", needs \(String(format: "%.2f", minimumScore))"
    }
}

/// What a person is told about drawing a character, for VoiceOver where the preview cannot
/// be hovered. Derived from the templates, so it names only the ways that are accepted.
public enum CharacterDrawingHelp {
    /// One line on what the templates forgive, for the Characters pane. Each clause is one
    /// of the alternative kinds the templates carry.
    public static let summary = "Letters can be drawn the way you write them: O from any point and either "
        + "way round, C, S, U, V and W backwards as well, B, D, M, N, P and R with the stem drawn down first, and "
        + "several lower-case shapes. Small hooks at the start and end are ignored."

    public static func text(for gesture: CharacterGesture) -> String {
        let what: String
        if gesture.isDirection {
            what = "Draw a straight line \(gesture.displayName)"
        } else if CharacterGesture.strokes.contains(gesture) {
            what = "Draw \(gesture.displayName) as one stroke with a corner"
        } else {
            what = "Draw the letter \(gesture.displayName)"
        }
        var text = what + " with two fingers spread apart on the trackpad, or with the right or middle "
            + "button held."

        if gesture.isDirection {
            text += " A small hook or wobble at either end is ignored."
        } else if !CharacterGesture.strokes.contains(gesture) {
            text += " The preview shows one way to draw it, starting at the dot."
            let kinds = Set(CharacterTemplates.all.filter { $0.gesture == gesture }.compactMap(\.alternativeKind))
            var ways: [String] = []
            if kinds.contains(.reversed) { ways.append("drawn backwards, from its end") }
            if kinds.contains(.anyStart) { ways.append("begun at any point and gone round either way") }
            if kinds.contains(.stemFirst) { ways.append("with the stem drawn down first") }
            if kinds.contains(.lowerCase) { ways.append("in a lower-case form") }
            if !ways.isEmpty {
                text += " It is also accepted \(ways.joined(separator: ", or "))."
            }
            text += " Small hooks at the start and end are ignored."
        }
        return text + " Which of these work depends on the drawing sources chosen above."
    }
}

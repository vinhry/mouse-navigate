import XCTest
@testable import MouseNavigateCore

/// Compares ways of matching, each at the strictness that lets the same share of
/// non-letters through, so that a matcher whose scores simply run higher gains nothing.
/// Set `MOUSENAVIGATE_STROKE_SWEEP=1`.
final class StrokeTuningSweep: XCTestCase {
    typealias Tuning = StrokeRecognizer.Tuning

    func testSweep() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["MOUSENAVIGATE_STROKE_SWEEP"] == "1", "set MOUSENAVIGATE_STROKE_SWEEP=1")
        let synthetic = StrokeEvaluation.genuineStrokes(perCell: 3, seed: 21)
            + StrokeEvaluation.negativeStrokes(perKind: 60, seed: 22)
        var real: [LabelledStroke] = []
        if let path = UJIPenCharacters.environmentPath {
            // Writers the database sets aside for training; the held-out ones are for the end.
            real = UJIPenCharacters.labelled(try UJIPenCharacters.load(path: path).filter { !$0.isTestWriter })
        }
        let only = environment["MOUSENAVIGATE_STROKE_SWEEP_ONLY"]
        var lines = ["config                         | thr   | letters taught natural | lines strokes | FA    | UJI taught natural | top-1 syn UJI | ms"]
        for (name, tuning, templates) in StrokeTuningSweep.configs() where only == nil || name.hasPrefix(only!) {
            let recognizer = StrokeRecognizer(templates: templates, tuning: tuning)
            let evaluated = EvaluatedRecognizer(name: name, match: { recognizer.bestMatch($0) }, accepts: { match, setting in
                var copy = recognizer
                copy.minimumScore = setting
                return copy.accepts(match)
            })
            let run = StrokeEvaluation.run(evaluated, on: synthetic)
            let realRun = StrokeEvaluation.run(evaluated, on: real)
            for (target, excluding) in [(0.05, nil), (0.02, nil), (0.02, StrokeEvaluation.Negative.arc), (-1, nil)] {
                // The loosest setting that keeps false accepts at or below the target, or the
                // default when the target is negative.
                var threshold = target < 0 ? StrokeEvaluation.balanced : 1.0
                for step in stride(from: 1.0, through: -1.0, by: -0.005) where target >= 0 {
                    if run.falseAcceptRate(at: step, excluding: excluding) <= target { threshold = step } else { break }
                }
                let letters = run.group(.letter)
                let realLetters = realRun.group(.letter)
                lines.append(String(
                    format: "%-30@ | %.3f | %@ %@ %@ | %@ %@ | %@ | %@ %@ | %@ %@ | %.3f",
                    name as NSString, threshold,
                    StrokeEvaluation.percent(run.accuracy(letters, at: threshold)),
                    StrokeEvaluation.percent(run.accuracy(letters.filter { $0.stroke.kind == .taught }, at: threshold)),
                    StrokeEvaluation.percent(run.accuracy(letters.filter { $0.stroke.kind == .natural }, at: threshold)),
                    StrokeEvaluation.percent(run.accuracy(run.group(.direction), at: threshold)),
                    StrokeEvaluation.percent(run.accuracy(run.group(.stroke), at: threshold)),
                    StrokeEvaluation.percent(run.falseAcceptRate(at: threshold)),
                    StrokeEvaluation.percent(realRun.accuracy(realLetters.filter { $0.stroke.kind == .taught }, at: threshold)),
                    StrokeEvaluation.percent(realRun.accuracy(realLetters.filter { $0.stroke.kind == .natural }, at: threshold)),
                    StrokeEvaluation.percent(run.accuracy(letters, at: -10)),
                    StrokeEvaluation.percent(realRun.accuracy(realLetters, at: -10)),
                    run.secondsPerStroke * 1000
                ))
            }
            if environment["MOUSENAVIGATE_STROKE_SWEEP_DETAIL"] == "1" {
                print(StrokeEvaluation.report([run]))
                print(StrokeEvaluation.report([realRun]))
            }
        }
        print(lines.joined(separator: "\n"))
    }

    /// Prints the ranked matches of a few real samples of the characters in
    /// `MOUSENAVIGATE_STROKE_PEEK`, training writers only.
    func testPeek() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["MOUSENAVIGATE_STROKE_PEEK"] != nil, "set MOUSENAVIGATE_STROKE_PEEK")
        let wanted = Array(environment["MOUSENAVIGATE_STROKE_PEEK"]!)
        let path = try XCTUnwrap(UJIPenCharacters.environmentPath)
        let samples = try UJIPenCharacters.load(path: path).filter { !$0.isTestWriter && wanted.contains($0.character) }
        let recognizer = StrokeRecognizer(templates: CharacterTemplates.all, tuning: StrokeTuningSweep.configs().first!.1)
        for sample in samples.prefix(Int(environment["MOUSENAVIGATE_STROKE_PEEK_COUNT"] ?? "6") ?? 6) {
            let ranked = recognizer.matches(sample.points).prefix(4).map { "\($0.gesture.displayName) \(String(format: "%.3f", $0.score))" }
            print("\(sample.character) \(sample.id): \(ranked.joined(separator: ", "))")
        }
    }

    static func configs() ->[(String, Tuning, [CharacterTemplate])] {
        var list: [(String, Tuning, [CharacterTemplate])] = []
        func add(_ name: String, templates: [CharacterTemplate] = CharacterTemplates.all, _ change: (inout Tuning) -> Void) {
            var tuning = Tuning()
            change(&tuning)
            list.append((name, tuning, templates))
        }
        add("default") { _ in }
        add("strokes stretched too") { $0.keepsProportions = [] }
        add("hooks kept") { $0.trimsHooks = false }
        add("not smoothed") { $0.smoothingPasses = 0 }
        add("positions only") { $0.directionWeight = 0 }
        add("uniform scale") { $0.aspectSoftening = 0 }
        add("no slant") { $0.slantSteps = 0 }
        add("narrow band") { $0.band = 1 }
        add("no alternatives", templates: CharacterTemplates.letters + CharacterTemplates.strokes) { _ in }
        return list
    }
}

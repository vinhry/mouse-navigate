import Foundation
@testable import MouseNavigateCore

/// Real handwriting: the UJI Pen Characters database, version 2, by F. Prat, M. Castro,
/// D. Llorens, A. Marzal and J. Vilar (Universitat Jaume I), from the UCI Machine Learning
/// Repository, doi:10.24432/C5FG8S, licensed CC BY 4.0. Sixty writers wrote every letter
/// twice with a stylus on a tablet PC; the pen's path was recorded, +y down.
///
/// It is pen on a tablet, not two fingers on a trackpad, and the writers wrote letters as
/// they normally do rather than as this app teaches. So it says how real hands vary the
/// shape of a letter (proportions, slant, where a loop starts, hooks), not how a trackpad
/// drawing looks. Only one-stroke samples are used, and only of letters whose usual
/// one-stroke form is one the app teaches or could reasonably take.
///
/// The full file is read from the path in `MOUSENAVIGATE_UJI_PATH` when set (download it
/// from the UCI repository; it is not kept here). A small sample of the test writers'
/// strokes is kept in Fixtures, with its attribution, for the ordinary test run.
enum UJIPenCharacters {
    struct Sample {
        let character: Character
        let id: String
        let points: [Vector2]

        /// The database splits its writers in two; "tst" writers are held out.
        var isTestWriter: Bool { id.hasPrefix("tst") }
    }

    /// Letters whose usual one-stroke form is the one the app's preview teaches. `I` is a
    /// straight line down.
    static let taught: [Character: CharacterGesture] = [
        "A": .a, "B": .b, "b": .b, "C": .c, "c": .c, "D": .d, "G": .g, "h": .h, "I": .down,
        "J": .j, "L": .l, "l": .l, "M": .m, "N": .n, "O": .o, "o": .o, "P": .p, "p": .p,
        "R": .r, "S": .s, "s": .s, "U": .u, "u": .u, "V": .v, "v": .v, "W": .w, "w": .w,
        "Y": .y, "y": .y, "Z": .z, "z": .z,
    ]

    /// Lower-case forms the app did not teach but that are common, distinct one-stroke
    /// letters. Cursive f, k and q, whose loops are like nothing the app draws, are left out,
    /// as are letters almost nobody wrote in one stroke.
    static let natural: [Character: CharacterGesture] = [
        "a": .a, "d": .d, "e": .e, "g": .g, "m": .m, "n": .n, "r": .r,
    ]

    static var environmentPath: String? {
        ProcessInfo.processInfo.environment["MOUSENAVIGATE_UJI_PATH"].flatMap { $0.isEmpty ? nil : $0 }
    }

    static func load(path: String) throws -> [Sample] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return parse(String(decoding: data, as: UTF8.self))
    }

    static func fixture() throws -> [Sample] {
        guard let url = Bundle.module.url(forResource: "ujipenchars2-sample", withExtension: "txt",
                                          subdirectory: "Fixtures")
        else { throw CocoaError(.fileNoSuchFile) }
        return parse(String(decoding: try Data(contentsOf: url), as: UTF8.self))
    }

    /// Reads the database's text format, keeping one-stroke samples only. Lines are
    /// `WORD <character> <id>`, `NUMSTROKES <n>` and `POINTS <n> # x y x y ...`; anything
    /// unexpected is skipped rather than trusted.
    static func parse(_ text: String) -> [Sample] {
        var samples: [Sample] = []
        var word: (Character, String)?
        var strokes = 0
        var pointLines = 0
        func finish(_ points: [Vector2]) {
            if let (character, id) = word, strokes == 1, pointLines == 1, points.count >= 2 {
                samples.append(Sample(character: character, id: id, points: points))
            }
        }
        var pending: [Vector2] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let fields = line.split(separator: " ")
            switch fields.first {
            case "WORD":
                finish(pending)
                pending = []
                strokes = 0
                pointLines = 0
                if fields.count >= 3, fields[1].count == 1, let character = fields[1].first {
                    word = (character, String(fields[2]))
                } else {
                    word = nil
                }
            case "NUMSTROKES":
                strokes = fields.count >= 2 ? Int(fields[1]) ?? 0 : 0
            case "POINTS":
                pointLines += 1
                guard let hash = fields.firstIndex(of: "#"), fields.count >= 2,
                      let declared = Int(fields[1]), declared <= 10_000
                else { continue }
                let numbers = fields[(hash + 1)...].compactMap { Double($0) }
                guard numbers.count == declared * 2 else { continue }
                pending = stride(from: 0, to: numbers.count, by: 2).map { Vector2(x: numbers[$0], y: numbers[$0 + 1]) }
            default:
                continue
            }
        }
        finish(pending)
        return samples
    }

    /// The samples of letters the app can be asked to read, labelled for the evaluation.
    static func labelled(_ samples: [Sample]) -> [LabelledStroke] {
        samples.compactMap { sample in
            let kind: ReferenceShape.Kind
            let gesture: CharacterGesture
            if let taughtGesture = taught[sample.character] {
                (kind, gesture) = (.taught, taughtGesture)
            } else if let naturalGesture = natural[sample.character] {
                (kind, gesture) = (.natural, naturalGesture)
            } else {
                return nil
            }
            return LabelledStroke(truth: gesture, group: gesture.isDirection ? .direction : .letter,
                                  form: "UJI \(sample.character)", kind: kind, strength: 1, points: sample.points)
        }
    }
}

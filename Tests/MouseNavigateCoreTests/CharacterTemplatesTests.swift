import XCTest
@testable import MouseNavigateCore

final class CharacterTemplatesTests: XCTestCase {
    private let directions: Set<CharacterGesture> = [.up, .down, .left, .right, .upLeft, .upRight, .downLeft, .downRight]
    private let twoLegged: [CharacterGesture] = [
        .leftThenUp, .rightThenUp, .upThenLeft, .upThenRight,
        .leftThenRight, .rightThenLeft, .upThenDown, .downThenUp,
    ]

    func testEveryLetterHasATemplate() {
        let templated = Set(CharacterTemplates.all.map(\.gesture))
        for gesture in CharacterGesture.allCases where !directions.contains(gesture) {
            XCTAssertTrue(templated.contains(gesture), "\(gesture) has no template")
        }
        XCTAssertTrue(templated.isDisjoint(with: directions), "straight strokes are recognised by being straight")
    }

    func testTwoLeggedStrokesComeWithAShortSecondLegToo() {
        for gesture in twoLegged {
            XCTAssertEqual(CharacterTemplates.all.filter { $0.gesture == gesture }.count, 2, "\(gesture)")
        }
    }

    /// Within the unit box, give or take a tail: Q's runs a little past the corner.
    func testTemplatesStayAboutTheUnitBox() {
        let range = -0.15...1.15
        for template in CharacterTemplates.all {
            XCTAssertGreaterThanOrEqual(template.points.count, 2, "\(template.gesture)")
            for point in template.points {
                XCTAssertTrue(range.contains(point.x) && range.contains(point.y),
                              "\(template.gesture) leaves the box at \(point)")
            }
        }
    }

    func testEveryGestureCanBeShown() {
        for gesture in CharacterGesture.allCases {
            XCTAssertGreaterThanOrEqual(CharacterTemplates.preview(for: gesture).count, 2, "\(gesture)")
        }
    }

    func testDirectionPreviewsPointTheirWay() {
        func travel(_ gesture: CharacterGesture) -> Vector2 {
            let points = CharacterTemplates.preview(for: gesture)
            return Vector2(x: points.last!.x - points.first!.x, y: points.last!.y - points.first!.y)
        }
        XCTAssertLessThan(travel(.up).y, 0, "+y is down")
        XCTAssertGreaterThan(travel(.down).y, 0)
        XCTAssertLessThan(travel(.left).x, 0)
        XCTAssertGreaterThan(travel(.downRight).x, 0)
        XCTAssertGreaterThan(travel(.downRight).y, 0)
    }

    func testAPreviewIsTheFirstTemplate() {
        let first = CharacterTemplates.all.first { $0.gesture == .leftThenUp }!
        XCTAssertEqual(CharacterTemplates.preview(for: .leftThenUp), first.points)
    }
}

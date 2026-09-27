import XCTest
@testable import MouseNavigateCore

final class GridNavigatorTests: XCTestCase {
    private let screen = Rect(minX: 0, minY: 0, maxX: 900, maxY: 600)

    func testCellsCoverTheRegionRowByRow() {
        let grid = GridNavigator(screen: screen)
        XCTAssertEqual(grid.cells.count, 9)
        XCTAssertEqual(grid.cells[0], Rect(minX: 0, minY: 0, maxX: 300, maxY: 200))
        XCTAssertEqual(grid.cells[4], Rect(minX: 300, minY: 200, maxX: 600, maxY: 400))
        XCTAssertEqual(grid.cells[8], Rect(minX: 600, minY: 400, maxX: 900, maxY: 600))
    }

    func testKeysPickCellsByPosition() {
        var grid = GridNavigator(screen: screen)
        XCTAssertTrue(grid.choose(keyCode: KeyCode.period))
        XCTAssertEqual(grid.region, Rect(minX: 600, minY: 400, maxX: 900, maxY: 600))
        XCTAssertEqual(grid.center, Vector2(x: 750, y: 500))

        XCTAssertTrue(grid.choose(keyCode: KeyCode.u))
        XCTAssertEqual(grid.region, Rect(minX: 600, minY: 400, maxX: 700, maxY: 466.6666666666667))
        XCTAssertEqual(grid.depth, 2)
    }

    func testOtherKeysPickNothing() {
        var grid = GridNavigator(screen: screen)
        XCTAssertFalse(grid.choose(keyCode: KeyCode.s))
        XCTAssertEqual(grid.region, screen)
        XCTAssertEqual(grid.depth, 0)
    }

    func testBackUndoesOneChoice() {
        var grid = GridNavigator(screen: screen)
        grid.choose(keyCode: KeyCode.k)
        grid.choose(keyCode: KeyCode.k)
        XCTAssertTrue(grid.back())
        XCTAssertEqual(grid.region, Rect(minX: 300, minY: 200, maxX: 600, maxY: 400))
        XCTAssertTrue(grid.back())
        XCTAssertEqual(grid.region, screen)
        XCTAssertFalse(grid.back())
    }

    func testStopsNarrowingOnceCellsGetTiny() {
        var grid = GridNavigator(screen: screen)
        var choices = 0
        while grid.choose(keyCode: KeyCode.k) {
            choices += 1
        }
        XCTAssertEqual(choices, 3)
        XCTAssertFalse(grid.canNarrow)
    }

    func testResetMovesToAnotherDisplay() {
        var grid = GridNavigator(screen: screen)
        grid.choose(keyCode: KeyCode.k)
        let other = Rect(minX: 900, minY: 0, maxX: 2900, maxY: 1000)
        grid.reset(to: other)
        XCTAssertEqual(grid.region, other)
        XCTAssertEqual(grid.depth, 0)
    }
}

final class HintLabelTests: XCTestCase {
    private let alphabet = HintLabels.alphabet(excluding: [KeyCode.a])

    func testActivationKeyIsNeverALetter() {
        XCTAssertFalse(alphabet.contains(KeyCode.a))
        XCTAssertEqual(alphabet.first, KeyCode.s)
        XCTAssertEqual(Set(alphabet).count, alphabet.count)
    }

    func testFewTargetsGetOneKeystroke() {
        let labels = HintLabels.generate(count: 5, alphabet: alphabet)
        XCTAssertEqual(labels, [[KeyCode.s], [KeyCode.d], [KeyCode.f], [KeyCode.j], [KeyCode.k]])
    }

    func testManyTargetsGetEqualLengthUniqueLabels() {
        let labels = HintLabels.generate(count: alphabet.count + 1, alphabet: alphabet)
        XCTAssertTrue(labels.allSatisfy { $0.count == 2 })
        XCTAssertEqual(Set(labels.map { $0.map(String.init).joined(separator: ",") }).count, labels.count)
        XCTAssertEqual(labels[0], [KeyCode.s, KeyCode.s])
        XCTAssertEqual(labels[1], [KeyCode.s, KeyCode.d])
    }

    func testLabelsForLargeCounts() {
        let count = alphabet.count * alphabet.count + 1
        let labels = HintLabels.generate(count: count, alphabet: alphabet)
        XCTAssertEqual(labels.count, count)
        XCTAssertTrue(labels.allSatisfy { $0.count == 3 })
    }

    func testEdgeCounts() {
        XCTAssertEqual(HintLabels.generate(count: 0, alphabet: alphabet), [])
        XCTAssertEqual(HintLabels.generate(count: 1, alphabet: [KeyCode.s]), [[KeyCode.s]])
        XCTAssertEqual(HintLabels.generate(count: 2, alphabet: []), [])
    }

    func testFilterNarrowsThenMatches() {
        var filter = HintFilter(labels: HintLabels.generate(count: 30, alphabet: alphabet))
        XCTAssertEqual(filter.type(KeyCode.s), .narrowed)
        XCTAssertTrue(filter.isVisible(0))
        XCTAssertFalse(filter.isVisible(29))
        XCTAssertEqual(filter.type(KeyCode.d), .matched(1))
    }

    func testFilterRejectsKeysThatFitNothing() {
        var filter = HintFilter(labels: HintLabels.generate(count: 3, alphabet: alphabet))
        XCTAssertEqual(filter.type(KeyCode.z), .rejected)
        XCTAssertEqual(filter.typed, [])
        XCTAssertEqual(filter.type(KeyCode.f), .matched(2))
    }

    func testDeleteGoesBackOneKey() {
        var filter = HintFilter(labels: HintLabels.generate(count: 30, alphabet: alphabet))
        _ = filter.type(KeyCode.s)
        XCTAssertTrue(filter.deleteLast())
        XCTAssertTrue(filter.isVisible(29))
        XCTAssertFalse(filter.deleteLast())
    }
}

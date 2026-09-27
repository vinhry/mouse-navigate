import Foundation

/// Narrows the pointer down to a spot on screen by repeatedly choosing one of nine cells.
///
/// Three choices on a 5K display land within about 60 points of anywhere, which is faster
/// than easing across it. Positions are CoreGraphics global points, +y down.
public struct GridNavigator {
    public static let columns = 3
    public static let rows = 3

    /// The keys that pick each cell, by physical position: the 3×3 block under the right
    /// hand, row by row. Key codes are positional, so this holds on any keyboard layout.
    public static let cellKeys: [UInt16] = [
        KeyCode.u, KeyCode.i, KeyCode.o,
        KeyCode.j, KeyCode.k, KeyCode.l,
        KeyCode.m, KeyCode.comma, KeyCode.period,
    ]

    /// Below this a cell is too small to be worth splitting again.
    public static let minimumCellSize = 12.0

    public private(set) var region: Rect
    /// Regions chosen so far, most recent last, so a choice can be undone.
    private var history: [Rect] = []

    public init(screen: Rect) {
        region = screen
    }

    public var depth: Int { history.count }

    public var center: Vector2 {
        Vector2(x: (region.minX + region.maxX) / 2, y: (region.minY + region.maxY) / 2)
    }

    /// The nine cells of the current region, row by row from the top left.
    public var cells: [Rect] {
        let width = (region.maxX - region.minX) / Double(Self.columns)
        let height = (region.maxY - region.minY) / Double(Self.rows)
        return (0..<Self.rows).flatMap { row in
            (0..<Self.columns).map { column in
                Rect(
                    minX: region.minX + Double(column) * width,
                    minY: region.minY + Double(row) * height,
                    maxX: region.minX + Double(column + 1) * width,
                    maxY: region.minY + Double(row + 1) * height
                )
            }
        }
    }

    public var canNarrow: Bool {
        (region.maxX - region.minX) / Double(Self.columns) >= Self.minimumCellSize
            && (region.maxY - region.minY) / Double(Self.rows) >= Self.minimumCellSize
    }

    /// Returns false when the key picks no cell or the region is already as small as it
    /// usefully gets.
    @discardableResult
    public mutating func choose(keyCode: UInt16) -> Bool {
        guard let index = Self.cellKeys.firstIndex(of: keyCode), canNarrow else { return false }
        history.append(region)
        region = cells[index]
        return true
    }

    /// Returns false at the top level, where there is nothing to go back to.
    @discardableResult
    public mutating func back() -> Bool {
        guard let previous = history.popLast() else { return false }
        region = previous
        return true
    }

    /// Starts over on another display.
    public mutating func reset(to screen: Rect) {
        region = screen
        history.removeAll()
    }
}

import AppKit
import MouseNavigateCore

/// Jumps the pointer by picking cells of a 3×3 grid, each pick splitting the last.
///
/// `U I O / J K L / M , .` pick a cell and bring the pointer to its middle, Delete goes back
/// one pick, 1–9 move the grid to that display, Return keeps the pointer where it is and
/// Escape puts it back where it started. Any other cursor key ends the grid and does its
/// usual job, so the click key clicks where the grid led.
final class GridMode: CursorModal {
    var onFinish: (() -> Void)?

    private var grid: GridNavigator
    private let startingPoint: Vector2
    private let exitKey: UInt16
    private let gridKey: UInt16
    private let move: (Vector2) -> Void
    private let overlay = ScreenOverlay()

    init(pointer: Vector2, exitKey: UInt16, gridKey: UInt16, move: @escaping (Vector2) -> Void) {
        startingPoint = pointer
        self.exitKey = exitKey
        self.gridKey = gridKey
        self.move = move

        let displays = ScreenOverlay.displayFrames()
        let current = displays.first { $0.contains(CGPoint(x: pointer.x, y: pointer.y)) }
            ?? displays.first ?? .zero
        grid = GridNavigator(screen: Rect(current))

        overlay.draw = { [weak self] display in
            self?.draw(on: display)
        }
        overlay.show()
    }

    func keyDown(_ keyCode: UInt16, flags: CGEventFlags) -> CursorModalResult {
        switch keyCode {
        case exitKey:
            move(startingPoint)
            return .finish
        case gridKey, KeyCode.returnKey:
            return .finish
        case KeyCode.delete:
            if grid.back() {
                moveToCenter()
            }
            return .consume
        default:
            break
        }

        if let display = KeyCode.digits.firstIndex(of: keyCode) {
            let displays = ScreenOverlay.displayFrames()
            if displays.indices.contains(display) {
                grid.reset(to: Rect(displays[display]))
                moveToCenter()
            }
            return .consume
        }

        if GridNavigator.cellKeys.contains(keyCode) {
            if grid.choose(keyCode: keyCode) {
                moveToCenter()
            }
            return .consume
        }

        return .finishAndForward
    }

    func close() {
        overlay.hide()
        overlay.draw = nil
    }

    private func moveToCenter() {
        move(grid.center)
        overlay.redraw()
    }

    // MARK: - Drawing

    private func draw(on display: CGRect) {
        let region = CGRect(grid.region)
        guard region.intersects(display) else { return }

        NSColor.black.withAlphaComponent(0.18).setFill()
        NSBezierPath(rect: region).fill()

        let lines = NSBezierPath()
        for cell in grid.cells.map(CGRect.init) {
            lines.appendRect(cell)
        }
        lines.lineWidth = 1
        NSColor.white.withAlphaComponent(0.75).setStroke()
        lines.stroke()

        NSColor(srgbRed: 1, green: 0.8, blue: 0.1, alpha: 0.95).setStroke()
        let border = NSBezierPath(rect: region.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        border.stroke()

        guard grid.canNarrow else { return }
        let cells = grid.cells.map(CGRect.init)
        let fontSize = min(max(min(cells[0].width, cells[0].height) * 0.28, 9), 40)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.black,
        ]
        for (cell, key) in zip(cells, GridNavigator.cellKeys) {
            let text = NSAttributedString(string: KeyCodeNames.name(for: key), attributes: attributes)
            let size = text.size()
            ScreenOverlay.drawBadge(
                text,
                at: CGPoint(x: cell.midX - size.width / 2 - 4, y: cell.midY - size.height / 2 - 1),
                within: cell,
                fill: NSColor(srgbRed: 1, green: 0.85, blue: 0.2, alpha: 0.9)
            )
        }
    }
}

extension Rect {
    init(_ rect: CGRect) {
        self.init(minX: Double(rect.minX), minY: Double(rect.minY), maxX: Double(rect.maxX), maxY: Double(rect.maxY))
    }
}

extension CGRect {
    init(_ rect: Rect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.maxX - rect.minX, height: rect.maxY - rect.minY)
    }
}

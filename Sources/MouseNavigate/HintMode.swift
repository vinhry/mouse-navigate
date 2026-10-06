import AppKit
import MouseNavigateCore

/// Labels everything clickable in the frontmost window; typing a label clicks it.
///
/// Shift on the last letter right-clicks instead, and Option only moves the pointer there.
/// Delete takes back a letter and Escape closes the hints.
final class HintMode: CursorModal {
    enum Click {
        case left
        case right
        /// Bring the pointer over without clicking.
        case none
    }

    var onFinish: (() -> Void)?

    private let exitKey: UInt16
    private let hintsKey: UInt16
    private let alphabet: [UInt16]
    private let activate: (CGPoint, Click) -> Void
    private let overlay = ScreenOverlay()

    private var targets: [AccessibilityScanner.Target] = []
    private var filter: HintFilter?
    private var message: String?
    private var isClosed = false

    private static let emptyMessageDuration: TimeInterval = 0.9

    init(
        excluding excluded: Set<UInt16>,
        exitKey: UInt16,
        hintsKey: UInt16,
        activate: @escaping (CGPoint, Click) -> Void
    ) {
        self.exitKey = exitKey
        self.hintsKey = hintsKey
        alphabet = HintLabels.alphabet(excluding: excluded.union([exitKey, hintsKey]))
        self.activate = activate

        overlay.draw = { [weak self] display in
            self?.draw(on: display)
        }
        scan()
    }

    // MARK: - Scanning

    private func scan() {
        guard let pid = FrontmostApp.shared.processIdentifier else {
            showMessage("No app in front")
            return
        }
        // AppKit's screen list is the main thread's to read.
        let displays = ScreenOverlay.displayFrames()
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let found = AccessibilityScanner.scan(pid: pid, displays: displays)
            DispatchQueue.main.async {
                self?.show(found)
            }
        }
    }

    private func show(_ found: [AccessibilityScanner.Target]) {
        guard !isClosed else { return }
        guard !found.isEmpty else {
            showMessage("Nothing to click here")
            return
        }
        targets = found
        filter = HintFilter(labels: HintLabels.generate(count: found.count, alphabet: alphabet))
        overlay.show()
    }

    /// Says why there are no hints, briefly, then gets out of the way.
    private func showMessage(_ text: String) {
        message = text
        overlay.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + HintMode.emptyMessageDuration) { [weak self] in
            guard let self, !self.isClosed else { return }
            self.onFinish?()
        }
    }

    // MARK: - Keys

    func keyDown(_ keyCode: UInt16, flags: CGEventFlags) -> CursorModalResult {
        if keyCode == exitKey || keyCode == hintsKey {
            return .finish
        }
        // Still scanning, or showing why there is nothing: keys wait rather than leak.
        guard var filter else { return .consume }

        if keyCode == KeyCode.delete {
            filter.deleteLast()
            self.filter = filter
            overlay.redraw()
            return .consume
        }

        switch filter.type(keyCode) {
        case .matched(let index):
            self.filter = filter
            let click: Click = flags.contains(.maskAlternate) ? .none : flags.contains(.maskShift) ? .right : .left
            activate(targets[index].center, click)
            return .finish
        case .narrowed:
            self.filter = filter
            overlay.redraw()
            return .consume
        case .rejected:
            NSSound.beep()
            return .consume
        }
    }

    func close() {
        isClosed = true
        overlay.hide()
        overlay.draw = nil
    }

    // MARK: - Drawing

    private static let labelFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
    private static let plate = NSColor(srgbRed: 1, green: 0.85, blue: 0.2, alpha: 0.95)

    private func draw(on display: CGRect) {
        if let message {
            drawMessage(message, on: display)
            return
        }
        guard let filter else { return }

        let typedCount = filter.typed.count
        for (index, target) in targets.enumerated() where filter.isVisible(index) {
            guard display.intersects(target.frame) else { continue }

            let letters = filter.labels[index].map { KeyboardLayout.shared.name(for: $0) }
            let text = NSMutableAttributedString()
            for (position, letter) in letters.enumerated() {
                // What has been typed already fades, leaving the letters still to type.
                let color = position < typedCount ? NSColor.black.withAlphaComponent(0.35) : NSColor.black
                text.append(NSAttributedString(string: letter, attributes: [
                    .font: HintMode.labelFont,
                    .foregroundColor: color,
                ]))
            }
            ScreenOverlay.drawBadge(
                text,
                at: CGPoint(x: target.frame.minX - 2, y: target.frame.minY - 2),
                within: display,
                fill: HintMode.plate
            )
        }
    }

    private func drawMessage(_ message: String, on display: CGRect) {
        let pointer = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = CGPoint(x: pointer.x, y: primaryHeight - pointer.y)
        guard display.contains(point) else { return }

        let text = NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.black,
        ])
        ScreenOverlay.drawBadge(
            text,
            at: CGPoint(x: point.x + 12, y: point.y + 12),
            within: display,
            fill: HintMode.plate,
            padding: CGSize(width: 8, height: 4)
        )
    }
}

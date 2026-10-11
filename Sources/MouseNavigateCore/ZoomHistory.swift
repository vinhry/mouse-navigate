import Foundation

/// What **Maximize Window** does: it fills the screen the window is on, and used again on a
/// window it filled, it puts the window back where it was.
///
/// Remembers the frame each window had before it was filled, for the last `capacity`
/// windows. Generic over what a window is, so the app can keep Accessibility elements,
/// which compare with `CFEqual`, and tests can keep numbers.
public struct ZoomHistory<Window> {
    public let capacity: Int
    private let isSame: (Window, Window) -> Bool
    private var saved: [(window: Window, frame: Rect)] = []

    public init(capacity: Int = 20, isSame: @escaping (Window, Window) -> Bool) {
        self.capacity = capacity
        self.isSame = isSame
    }

    public var count: Int { saved.count }

    /// The frame `window`, now at `frame`, should take. Nil only when there are no screens.
    public mutating func zoom(_ window: Window, from frame: Rect, screens: [Rect]) -> Rect? {
        guard let index = WindowLayout.screenIndex(for: frame, in: screens) else { return nil }
        let target = screens[index]

        if frame.approximatelyEquals(target), let at = saved.lastIndex(where: { isSame($0.window, window) }) {
            let restored = saved.remove(at: at).frame
            // Saved before a display was unplugged or moved, the frame may now be off every
            // screen; a window sent there could not be reached again.
            if screens.contains(where: { $0.intersectionArea(with: restored) > 0 }) {
                return restored
            }
        }

        saved.removeAll { isSame($0.window, window) }
        saved.append((window, frame))
        if saved.count > capacity {
            saved.removeFirst()
        }
        return target
    }
}

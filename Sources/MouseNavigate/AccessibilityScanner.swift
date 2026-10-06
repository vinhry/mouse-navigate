import AppKit
import ApplicationServices

/// Finds what can be clicked in the frontmost window, through the Accessibility permission
/// the app already has.
///
/// Every attribute read is a round trip to the other app, so the walk is bounded three
/// ways: a timeout on each request, a cap on elements visited and a deadline for the
/// whole scan. A huge web page gets the targets found in time rather than a hang. Safe to
/// run off the main thread, given the display frames, which only the main thread may ask
/// AppKit for.
enum AccessibilityScanner {
    struct Target {
        /// The visible part, in CoreGraphics global points.
        var frame: CGRect
        var role: String

        var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
    }

    /// Things a click does something to.
    private static let clickableRoles: Set<String> = [
        kAXButtonRole, "AXLink", kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole,
        kAXMenuButtonRole, kAXComboBoxRole, kAXTextFieldRole, kAXTextAreaRole,
        kAXDisclosureTriangleRole, kAXRowRole, kAXColorWellRole, kAXMenuBarItemRole,
    ]

    /// Containers that cut off what is scrolled out of them.
    private static let clippingRoles: Set<String> = [
        kAXScrollAreaRole, kAXWindowRole, kAXSheetRole,
    ]

    /// Clickable things that hold nothing worth a hint of its own. Rows are left out:
    /// their buttons and fields are what gets clicked.
    private static let opaqueRoles = clickableRoles.subtracting([kAXRowRole])

    private static let attributes = [
        kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute,
        kAXVisibleChildrenAttribute, kAXChildrenAttribute,
    ] as CFArray

    static func scan(pid: pid_t, displays: [CGRect], maxElements: Int = 4000, budget: TimeInterval = 0.4) -> [Target] {
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        let app = AXUIElementCreateApplication(pid)
        bound(app, until: deadline)
        // Electron and Chromium build their accessibility tree only when asked; every
        // other app ignores this.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else {
            return []
        }
        let window = focused as! AXUIElement

        var targets: [Target] = []
        var queue: [(element: AXUIElement, clip: CGRect)] = [(window, .infinite)]
        var next = 0

        while next < queue.count, next < maxElements, ProcessInfo.processInfo.systemUptime < deadline {
            let (element, clip) = queue[next]
            next += 1

            // The timeout is per element, so each one gets what is left of the budget.
            bound(element, until: deadline)
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &raw) == .success,
                  let values = raw as? [AnyObject], values.count == 5
            else {
                continue
            }

            let role = values[0] as? String ?? ""
            let frame = Self.frame(position: values[1], size: values[2])

            var childClip = clip
            if let frame, frame.width > 0, frame.height > 0 {
                let visible = frame.intersection(clip)
                // Scrolled out of view, so nothing inside it can be seen either.
                if visible.isNull || visible.isEmpty {
                    continue
                }
                if clickableRoles.contains(role), visible.width >= 4, visible.height >= 4,
                   displays.contains(where: { $0.intersects(visible) }) {
                    targets.append(Target(frame: visible, role: role))
                }
                if clippingRoles.contains(role) {
                    childClip = visible
                }
            }

            if opaqueRoles.contains(role) {
                continue
            }
            let children = Self.elements(values[3]) ?? Self.elements(values[4]) ?? []
            queue.append(contentsOf: children.map { ($0, childClip) })
        }

        return arrange(deduplicate(targets))
    }

    // MARK: - Helpers

    /// No single request may outlive the scan's deadline by much, nor be cut so short that
    /// a healthy app cannot answer at all.
    private static func bound(_ element: AXUIElement, until deadline: TimeInterval) {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        AXUIElementSetMessagingTimeout(element, Float(min(max(remaining, 0.05), 0.2)))
    }

    private static func frame(position: AnyObject, size: AnyObject) -> CGRect? {
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else {
            return nil
        }
        return CGRect(origin: point, size: extent)
    }

    /// An empty list counts as none, so a missing visible-children list falls back to the
    /// full one.
    private static func elements(_ value: AnyObject) -> [AXUIElement]? {
        guard let array = value as? [AnyObject], !array.isEmpty else { return nil }
        let elements = array.filter { CFGetTypeID($0) == AXUIElementGetTypeID() }.map { $0 as! AXUIElement }
        return elements.isEmpty ? nil : elements
    }

    /// A link wrapping a button, or a row and the field that fills it, would otherwise get
    /// two hints on the same spot. The first found, the outermost, is kept.
    private static func deduplicate(_ targets: [Target]) -> [Target] {
        var kept: [Target] = []
        for target in targets where !kept.contains(where: {
            abs($0.center.x - target.center.x) < 6 && abs($0.center.y - target.center.y) < 6
        }) {
            kept.append(target)
        }
        return kept
    }

    /// Reading order, so labels run the way the eye does.
    private static func arrange(_ targets: [Target]) -> [Target] {
        targets.sorted {
            abs($0.frame.minY - $1.frame.minY) > 4 ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX
        }
    }
}

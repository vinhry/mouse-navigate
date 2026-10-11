import Foundation

/// Which axes a wheel scrolls the other way. Not `none`: that reads as `Optional.none`
/// wherever an optional reverse is expected, and silently means "unset".
public enum ScrollReverse: String, CaseIterable, Sendable {
    case off
    case vertical
    case horizontal
    case both

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .vertical: return "Vertical"
        case .horizontal: return "Horizontal"
        case .both: return "Both"
        }
    }

    public var reversesVertical: Bool { self == .vertical || self == .both }
    public var reversesHorizontal: Bool { self == .horizontal || self == .both }
}

/// The settings a wheel has, by name: the names are the settings keys and the fields of
/// a per-app override, so one list serves storage, export and the registry.
public enum ScrollField: String, CaseIterable {
    case reverse
    case verticalSpeed
    case horizontalSpeed
    case smooth
    /// Smooth scrolling that coasts on after a flick, the way a trackpad does.
    case momentum
    case shiftSwapsAxes
    case optionPrecise
    case commandFast

    public var valueType: SettingsKey.ValueType {
        switch self {
        case .reverse: return .string
        case .verticalSpeed, .horizontalSpeed: return .double
        case .smooth, .momentum, .shiftSwapsAxes, .optionPrecise, .commandFast: return .bool
        }
    }
}

/// How a mouse wheel's scrolling is reshaped. Trackpads and the Magic Mouse scroll
/// continuously and are never touched.
public struct ScrollSettings: Equatable, Sendable {
    public var reverse: ScrollReverse
    public var verticalSpeed: Double
    public var horizontalSpeed: Double
    public var isSmooth: Bool
    /// With `isSmooth`, a flick of the wheel coasts on as a trackpad does, and the scroll
    /// carries a trackpad's gesture phases. Nothing without it.
    public var hasMomentum: Bool
    /// ⇧ held while scrolling turns the wheel sideways.
    public var shiftSwapsAxes: Bool
    /// ⌥ held while scrolling slows the wheel to a quarter.
    public var optionIsPrecise: Bool
    /// ⌘ held while scrolling triples the wheel.
    public var commandIsFast: Bool

    public static let speedRange: ClosedRange<Double> = 0.5...4
    public static let preciseFactor = 0.25
    public static let fastFactor = 3.0
    public static let standard = ScrollSettings()

    public init(
        reverse: ScrollReverse = .off,
        verticalSpeed: Double = 1,
        horizontalSpeed: Double = 1,
        isSmooth: Bool = false,
        hasMomentum: Bool = false,
        shiftSwapsAxes: Bool = false,
        optionIsPrecise: Bool = false,
        commandIsFast: Bool = false
    ) {
        self.reverse = reverse
        self.verticalSpeed = ScrollSettings.clampSpeed(verticalSpeed)
        self.horizontalSpeed = ScrollSettings.clampSpeed(horizontalSpeed)
        self.isSmooth = isSmooth
        self.hasMomentum = hasMomentum
        self.shiftSwapsAxes = shiftSwapsAxes
        self.optionIsPrecise = optionIsPrecise
        self.commandIsFast = commandIsFast
    }

    /// Whether wheel events need to pass through the app at all.
    public var isActive: Bool {
        self != .standard
    }

    public static func clampSpeed(_ speed: Double) -> Double {
        min(max(speed, speedRange.lowerBound), speedRange.upperBound)
    }
}

/// What one scope, a mouse model or an app, sets for the wheel. A field left nil follows
/// the scope beneath, so a hand-edited settings file can change one thing for one app.
public struct ScrollOverride: Equatable, Sendable {
    public var reverse: ScrollReverse?
    public var verticalSpeed: Double?
    public var horizontalSpeed: Double?
    public var isSmooth: Bool?
    public var hasMomentum: Bool?
    public var shiftSwapsAxes: Bool?
    public var optionIsPrecise: Bool?
    public var commandIsFast: Bool?

    public static let none = ScrollOverride()

    public init(
        reverse: ScrollReverse? = nil,
        verticalSpeed: Double? = nil,
        horizontalSpeed: Double? = nil,
        isSmooth: Bool? = nil,
        hasMomentum: Bool? = nil,
        shiftSwapsAxes: Bool? = nil,
        optionIsPrecise: Bool? = nil,
        commandIsFast: Bool? = nil
    ) {
        self.reverse = reverse
        self.verticalSpeed = verticalSpeed.map(ScrollSettings.clampSpeed)
        self.horizontalSpeed = horizontalSpeed.map(ScrollSettings.clampSpeed)
        self.isSmooth = isSmooth
        self.hasMomentum = hasMomentum
        self.shiftSwapsAxes = shiftSwapsAxes
        self.optionIsPrecise = optionIsPrecise
        self.commandIsFast = commandIsFast
    }

    /// Every field set, as the preferences window writes a scope that has its own settings.
    public init(settings: ScrollSettings) {
        self.init(
            reverse: settings.reverse,
            verticalSpeed: settings.verticalSpeed,
            horizontalSpeed: settings.horizontalSpeed,
            isSmooth: settings.isSmooth,
            hasMomentum: settings.hasMomentum,
            shiftSwapsAxes: settings.shiftSwapsAxes,
            optionIsPrecise: settings.optionIsPrecise,
            commandIsFast: settings.commandIsFast
        )
    }

    public var isEmpty: Bool {
        self == .none
    }

    public func applied(to base: ScrollSettings) -> ScrollSettings {
        ScrollSettings(
            reverse: reverse ?? base.reverse,
            verticalSpeed: verticalSpeed ?? base.verticalSpeed,
            horizontalSpeed: horizontalSpeed ?? base.horizontalSpeed,
            isSmooth: isSmooth ?? base.isSmooth,
            hasMomentum: hasMomentum ?? base.hasMomentum,
            shiftSwapsAxes: shiftSwapsAxes ?? base.shiftSwapsAxes,
            optionIsPrecise: optionIsPrecise ?? base.optionIsPrecise,
            commandIsFast: commandIsFast ?? base.commandIsFast
        )
    }

    // MARK: - Fields

    /// The field's value as a property list holds it, nil when the field is not set.
    public func value(of field: ScrollField) -> Any? {
        switch field {
        case .reverse: return reverse?.rawValue
        case .verticalSpeed: return verticalSpeed
        case .horizontalSpeed: return horizontalSpeed
        case .smooth: return isSmooth
        case .momentum: return hasMomentum
        case .shiftSwapsAxes: return shiftSwapsAxes
        case .optionPrecise: return optionIsPrecise
        case .commandFast: return commandIsFast
        }
    }

    /// Sets a field from a property-list value. A value of the wrong kind leaves the
    /// field unset rather than failing the lot.
    public mutating func set(_ field: ScrollField, to value: Any?) {
        switch field {
        case .reverse: reverse = (value as? String).flatMap(ScrollReverse.init(rawValue:))
        case .verticalSpeed: verticalSpeed = ScrollOverride.number(value).map(ScrollSettings.clampSpeed)
        case .horizontalSpeed: horizontalSpeed = ScrollOverride.number(value).map(ScrollSettings.clampSpeed)
        case .smooth: isSmooth = ScrollOverride.bool(value)
        case .momentum: hasMomentum = ScrollOverride.bool(value)
        case .shiftSwapsAxes: shiftSwapsAxes = ScrollOverride.bool(value)
        case .optionPrecise: optionIsPrecise = ScrollOverride.bool(value)
        case .commandFast: commandIsFast = ScrollOverride.bool(value)
        }
    }

    /// A number of any kind, as a hand-edited file writes "2" for a speed; never a boolean.
    private static func number(_ value: Any?) -> Double? {
        guard let value, CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let value, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
        return value as? Bool
    }

    /// Only the fields that are set, keyed by field name.
    public var propertyList: [String: Any] {
        var result: [String: Any] = [:]
        for field in ScrollField.allCases {
            if let value = value(of: field) {
                result[field.rawValue] = value
            }
        }
        return result
    }

    /// Tolerant: anything but a dictionary, or any entry of the wrong kind, reads as unset.
    public init(propertyList: Any?) {
        self.init()
        guard let dictionary = propertyList as? [String: Any] else { return }
        for field in ScrollField.allCases {
            set(field, to: dictionary[field.rawValue])
        }
    }
}

/// Decides what the wheel does with a given mouse and app in front.
public enum ScrollResolver {
    /// The app's own settings win, then the mouse model's, then the ones for all.
    public static func resolve(global: ScrollSettings, profile: ScrollOverride?, app: ScrollOverride?) -> ScrollSettings {
        var settings = global
        if let profile {
            settings = profile.applied(to: settings)
        }
        if let app {
            settings = app.applied(to: settings)
        }
        return settings
    }
}

/// One wheel event's movement on both axes, in the three forms a scroll event carries it.
/// Axis 1 is vertical and axis 2 horizontal, as CoreGraphics numbers them.
public struct ScrollDelta: Equatable {
    public var lines: (vertical: Int, horizontal: Int)
    public var fixedLines: (vertical: Double, horizontal: Double)
    public var points: (vertical: Double, horizontal: Double)

    public init(
        lines: (vertical: Int, horizontal: Int),
        fixedLines: (vertical: Double, horizontal: Double),
        points: (vertical: Double, horizontal: Double)
    ) {
        self.lines = lines
        self.fixedLines = fixedLines
        self.points = points
    }

    public static func == (lhs: ScrollDelta, rhs: ScrollDelta) -> Bool {
        lhs.lines == rhs.lines && lhs.fixedLines == rhs.fixedLines && lhs.points == rhs.points
    }
}

/// A wheel event after the settings and the held modifiers have had their say.
public struct ModifiedScroll: Equatable {
    public var delta: ScrollDelta
    /// Modifiers a wheel option acted on. They are taken off the event: AppKit scrolls
    /// sideways on its own for ⇧, and browsers zoom on ⌘, so a modifier left on would be
    /// applied twice.
    public var consumedModifiers: Shortcut.Modifiers

    public init(delta: ScrollDelta, consumedModifiers: Shortcut.Modifiers) {
        self.delta = delta
        self.consumedModifiers = consumedModifiers
    }
}

public enum ScrollTransform {
    /// Reverses and scales every form of the delta alike, so an app gets the same answer
    /// whichever one it reads.
    public static func apply(_ delta: ScrollDelta, settings: ScrollSettings) -> ScrollDelta {
        apply(delta, settings: settings, modifiers: []).delta
    }

    /// The same, with the modifiers held: ⌥ for precision wins over ⌘ for speed, as the
    /// keyboard cursor's tiers do, and ⇧ swaps the axes last, after each axis has been
    /// reversed and scaled on its own, so a reversed vertical wheel turned sideways is
    /// still the reversed one.
    public static func apply(_ delta: ScrollDelta, settings: ScrollSettings, modifiers: Shortcut.Modifiers) -> ModifiedScroll {
        var modifierFactor = 1.0
        var consumed: Shortcut.Modifiers = []
        if settings.optionIsPrecise, modifiers.contains(.option) {
            modifierFactor = ScrollSettings.preciseFactor
            consumed.insert(.option)
        } else if settings.commandIsFast, modifiers.contains(.command) {
            modifierFactor = ScrollSettings.fastFactor
            consumed.insert(.command)
        }
        let vertical = settings.verticalSpeed * modifierFactor * (settings.reverse.reversesVertical ? -1 : 1)
        let horizontal = settings.horizontalSpeed * modifierFactor * (settings.reverse.reversesHorizontal ? -1 : 1)

        var result = ScrollDelta(
            lines: (scaleLines(delta.lines.vertical, by: vertical), scaleLines(delta.lines.horizontal, by: horizontal)),
            fixedLines: (delta.fixedLines.vertical * vertical, delta.fixedLines.horizontal * horizontal),
            points: (delta.points.vertical * vertical, delta.points.horizontal * horizontal)
        )
        if settings.shiftSwapsAxes, modifiers.contains(.shift) {
            result = ScrollDelta(
                lines: (result.lines.horizontal, result.lines.vertical),
                fixedLines: (result.fixedLines.horizontal, result.fixedLines.vertical),
                points: (result.points.horizontal, result.points.vertical)
            )
            consumed.insert(.shift)
        }
        return ModifiedScroll(delta: result, consumedModifiers: consumed)
    }

    /// Whole lines, rounded, but never to zero: slowing the wheel down must not make a
    /// notch do nothing.
    static func scaleLines(_ lines: Int, by factor: Double) -> Int {
        guard lines != 0 else { return 0 }
        let scaled = (Double(lines) * factor).rounded()
        if scaled == 0 {
            return factor * Double(lines) > 0 ? 1 : -1
        }
        return Int(scaled)
    }
}

/// Spreads each wheel notch over a few frames instead of jumping the whole way at once.
///
/// Every notch adds its distance to what is still to travel; each frame covers a share of
/// that, so a quick run of notches speeds up and a pause lets it settle. Turning the wheel
/// the other way drops whatever was left in the old direction.
public struct ScrollSmoother: Sendable {
    /// How quickly the remaining distance is used up: after this long about 63% of it has
    /// been scrolled.
    public var timeConstant: TimeInterval

    private var remaining = (vertical: 0.0, horizontal: 0.0)
    /// Fractions of a point not yet sent, so rounding never loses distance.
    private var carry = (vertical: 0.0, horizontal: 0.0)

    public init(timeConstant: TimeInterval = 0.08) {
        self.timeConstant = timeConstant
    }

    public var isIdle: Bool {
        remaining.vertical == 0 && remaining.horizontal == 0
    }

    /// What is still to travel, in points.
    public var remainingDistance: (vertical: Double, horizontal: Double) {
        remaining
    }

    public mutating func add(vertical: Double, horizontal: Double) {
        remaining.vertical = Self.combine(remaining.vertical, vertical)
        remaining.horizontal = Self.combine(remaining.horizontal, horizontal)
    }

    /// Whole points to scroll this frame.
    public mutating func step(elapsed: TimeInterval) -> (vertical: Int, horizontal: Int) {
        let share = timeConstant > 0 ? 1 - exp(-elapsed / timeConstant) : 1
        let vertical = advance(&remaining.vertical, carry: &carry.vertical, share: share)
        let horizontal = advance(&remaining.horizontal, carry: &carry.horizontal, share: share)
        return (vertical, horizontal)
    }

    public mutating func stop() {
        remaining = (0, 0)
        carry = (0, 0)
    }

    private static func combine(_ current: Double, _ added: Double) -> Double {
        if added == 0 { return current }
        if current == 0 || (current > 0) == (added > 0) { return current + added }
        return added
    }

    private func advance(_ remaining: inout Double, carry: inout Double, share: Double) -> Int {
        guard remaining != 0 else { return 0 }

        // The last sliver goes in one step rather than trailing off for ever.
        var move = remaining * share
        if abs(remaining - move) < 0.5 {
            move = remaining
        }
        remaining -= move
        if remaining == 0 {
            // Whatever is left over is sent now, so the total always adds up.
            move += carry
            carry = 0
            return Int(move.rounded())
        }
        carry += move
        let whole = carry.rounded(.towardZero)
        carry -= whole
        return Int(whole)
    }
}

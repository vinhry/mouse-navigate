import Foundation

/// How a mouse's speed up as it moves faster is decided.
public enum PointerAccelerationMode: String, CaseIterable, Sendable {
    /// What System Settings → Mouse → Tracking speed says, left alone.
    case system
    /// None: the pointer moves in proportion to the mouse however fast it goes, which is
    /// what games and drawing want.
    case off
    /// A curve of its own, `PointerSettings.acceleration`, in place of the system's.
    case custom

    public var displayName: String {
        switch self {
        case .system: return "As in System Settings"
        case .off: return "Off"
        case .custom: return "Custom"
        }
    }
}

/// The pointer settings a mouse has, by name: the names are the settings keys, as with the
/// wheel's.
public enum PointerField: String, CaseIterable, Sendable {
    case speed
    case accelerationMode
    case acceleration

    public var valueType: SettingsKey.ValueType {
        switch self {
        case .speed, .acceleration: return .double
        case .accelerationMode: return .string
        }
    }
}

/// How a mouse moves the pointer. Trackpads are never touched.
public struct PointerSettings: Equatable, Sendable {
    /// How far the pointer goes for the same movement, against the mouse as it comes: 2 is
    /// twice as far. Applied before acceleration.
    public var speed: Double
    public var accelerationMode: PointerAccelerationMode
    /// The curve for `.custom`, on System Settings' own scale from 0, none, to 3, the most.
    public var acceleration: Double

    public static let speedRange: ClosedRange<Double> = 0.25...4
    public static let accelerationRange: ClosedRange<Double> = 0...3
    public static let standard = PointerSettings()

    public init(speed: Double = 1, accelerationMode: PointerAccelerationMode = .system, acceleration: Double = 1) {
        self.speed = PointerSettings.clamp(speed, to: PointerSettings.speedRange)
        self.accelerationMode = accelerationMode
        self.acceleration = PointerSettings.clamp(acceleration, to: PointerSettings.accelerationRange)
    }

    /// Whether the pointer needs anything done to it at all.
    public var isActive: Bool {
        speed != 1 || accelerationMode != .system
    }

    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// What a mouse model sets for the pointer. A field left nil follows the settings for all
/// mice, as with the wheel.
public struct PointerOverride: Equatable, Sendable {
    public var speed: Double?
    public var accelerationMode: PointerAccelerationMode?
    public var acceleration: Double?

    public static let none = PointerOverride()

    public init(speed: Double? = nil, accelerationMode: PointerAccelerationMode? = nil, acceleration: Double? = nil) {
        self.speed = speed.map { PointerSettings.clamp($0, to: PointerSettings.speedRange) }
        self.accelerationMode = accelerationMode
        self.acceleration = acceleration.map { PointerSettings.clamp($0, to: PointerSettings.accelerationRange) }
    }

    /// Every field set, as the settings window writes a mouse that has its own settings.
    public init(settings: PointerSettings) {
        self.init(speed: settings.speed, accelerationMode: settings.accelerationMode, acceleration: settings.acceleration)
    }

    public var isEmpty: Bool { self == .none }

    public func applied(to base: PointerSettings) -> PointerSettings {
        PointerSettings(
            speed: speed ?? base.speed,
            accelerationMode: accelerationMode ?? base.accelerationMode,
            acceleration: acceleration ?? base.acceleration
        )
    }

    /// The field's value as a property list holds it, nil when the field is not set.
    public func value(of field: PointerField) -> Any? {
        switch field {
        case .speed: return speed
        case .accelerationMode: return accelerationMode?.rawValue
        case .acceleration: return acceleration
        }
    }

    /// Sets a field from a property-list value. A value of the wrong kind leaves it unset.
    public mutating func set(_ field: PointerField, to value: Any?) {
        switch field {
        case .speed:
            speed = PointerOverride.number(value).map { PointerSettings.clamp($0, to: PointerSettings.speedRange) }
        case .accelerationMode:
            accelerationMode = (value as? String).flatMap(PointerAccelerationMode.init(rawValue:))
        case .acceleration:
            acceleration = PointerOverride.number(value).map { PointerSettings.clamp($0, to: PointerSettings.accelerationRange) }
        }
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value, CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        return (value as? NSNumber)?.doubleValue
    }
}

/// The numbers macOS keeps for a mouse, worked out from the settings.
///
/// Both are IOFixed, 16.16. macOS divides a mouse's movement by its resolution, in dots
/// per inch, so a lower resolution moves the pointer further; it takes 400 when the mouse
/// says nothing. Acceleration is the Tracking speed slider's value, or −1 for none.
public enum PointerMath {
    public static let defaultResolution = 400.0
    public static let resolutionRange: ClosedRange<Double> = 10...1995
    /// What macOS uses for Tracking speed until it is moved.
    public static let defaultSystemAcceleration = 0.6875
    public static let accelerationOff = -65536

    public static func fixed(_ value: Double) -> Int {
        Int((value * 65536).rounded())
    }

    /// The resolution that makes the pointer go `speed` times as far as it does by default.
    public static func resolution(speed: Double) -> Int {
        let dotsPerInch = defaultResolution / max(speed, 0.0001)
        return fixed(PointerSettings.clamp(dotsPerInch, to: resolutionRange))
    }

    /// The acceleration to set, given what System Settings has for Tracking speed.
    public static func acceleration(for settings: PointerSettings, systemAcceleration: Double) -> Int {
        switch settings.accelerationMode {
        case .system: return fixed(systemAcceleration)
        case .off: return accelerationOff
        case .custom: return fixed(settings.acceleration)
        }
    }
}

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
    case accelerationMode
    case acceleration

    public var valueType: SettingsKey.ValueType {
        switch self {
        case .acceleration: return .double
        case .accelerationMode: return .string
        }
    }
}

/// How a mouse moves the pointer. Trackpads are never touched.
///
/// Acceleration is all macOS lets an app change on a mouse: it refuses the resolution and
/// the linear scaling switch that would make a separate speed, so a faster pointer is a
/// custom curve beyond what System Settings offers.
public struct PointerSettings: Equatable, Sendable {
    public var accelerationMode: PointerAccelerationMode
    /// The curve for `.custom`, on System Settings' Tracking speed scale: 0 is the slowest
    /// with the least acceleration, 3 the fastest System Settings offers, and above that
    /// faster still.
    public var acceleration: Double

    public static let accelerationRange: ClosedRange<Double> = 0...5
    /// The fastest System Settings' own slider goes.
    public static let systemMaximum = 3.0
    public static let standard = PointerSettings()

    public init(accelerationMode: PointerAccelerationMode = .system, acceleration: Double = 1) {
        self.accelerationMode = accelerationMode
        self.acceleration = PointerSettings.clamp(acceleration, to: PointerSettings.accelerationRange)
    }

    /// Whether the pointer needs anything done to it at all.
    public var isActive: Bool {
        accelerationMode != .system
    }

    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// What a mouse model sets for the pointer. A field left nil follows the settings for all
/// mice, as with the wheel.
public struct PointerOverride: Equatable, Sendable {
    public var accelerationMode: PointerAccelerationMode?
    public var acceleration: Double?

    public static let none = PointerOverride()

    public init(accelerationMode: PointerAccelerationMode? = nil, acceleration: Double? = nil) {
        self.accelerationMode = accelerationMode
        self.acceleration = acceleration.map { PointerSettings.clamp($0, to: PointerSettings.accelerationRange) }
    }

    /// Every field set, as the settings window writes a mouse that has its own settings.
    public init(settings: PointerSettings) {
        self.init(accelerationMode: settings.accelerationMode, acceleration: settings.acceleration)
    }

    public var isEmpty: Bool { self == .none }

    public func applied(to base: PointerSettings) -> PointerSettings {
        PointerSettings(
            accelerationMode: accelerationMode ?? base.accelerationMode,
            acceleration: acceleration ?? base.acceleration
        )
    }

    /// The field's value as a property list holds it, nil when the field is not set.
    public func value(of field: PointerField) -> Any? {
        switch field {
        case .accelerationMode: return accelerationMode?.rawValue
        case .acceleration: return acceleration
        }
    }

    /// Sets a field from a property-list value. A value of the wrong kind leaves it unset.
    public mutating func set(_ field: PointerField, to value: Any?) {
        switch field {
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

/// The number macOS keeps for a mouse's acceleration, worked out from the settings: the
/// Tracking speed slider's value, or −1 for none, in IOFixed, 16.16.
public enum PointerMath {
    /// What macOS uses for Tracking speed until it is moved.
    public static let defaultSystemAcceleration = 0.6875
    public static let accelerationOff = -65536

    public static func fixed(_ value: Double) -> Int {
        Int((value * 65536).rounded())
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

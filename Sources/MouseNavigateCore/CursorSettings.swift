import Foundation

/// Every rebindable key in cursor mode. The raw value doubles as the UserDefaults
/// suffix and as a stable identifier for the preferences UI.
public enum CursorBinding: String, CaseIterable {
    case activate
    case moveUp
    case moveDown
    case moveLeft
    case moveRight
    case leftClick
    case rightClick
    case middleClick
    case scrollModifier
    case lock
    case exit

    public var displayName: String {
        switch self {
        case .activate: return "Activate (hold)"
        case .moveUp: return "Move Up"
        case .moveDown: return "Move Down"
        case .moveLeft: return "Move Left"
        case .moveRight: return "Move Right"
        case .leftClick: return "Left Click"
        case .rightClick: return "Right Click"
        case .middleClick: return "Middle Click"
        case .scrollModifier: return "Scroll (hold)"
        case .lock: return "Toggle Lock"
        case .exit: return "Exit"
        }
    }

    public var defaultKeyCode: UInt16 {
        switch self {
        case .activate: return KeyCode.a
        case .moveUp: return KeyCode.i
        case .moveDown: return KeyCode.k
        case .moveLeft: return KeyCode.j
        case .moveRight: return KeyCode.l
        case .leftClick: return KeyCode.s
        case .rightClick: return KeyCode.d
        case .middleClick: return KeyCode.f
        case .scrollModifier: return KeyCode.space
        case .lock: return KeyCode.semicolon
        case .exit: return KeyCode.escape
        }
    }
}

/// Numeric tunables, each with the range the preferences sliders expose.
public enum CursorSetting: String, CaseIterable {
    case holdThreshold
    case baseSpeed
    case maxSpeed
    case acceleration
    case fastMultiplier
    case fasterMultiplier
    case precisionMultiplier
    case scrollSpeed

    public var displayName: String {
        switch self {
        case .holdThreshold: return "Hold to activate"
        case .baseSpeed: return "Start speed"
        case .maxSpeed: return "Top speed"
        case .acceleration: return "Ramp-up time"
        case .fastMultiplier: return "Shift multiplier"
        case .fasterMultiplier: return "Shift+Ctrl multiplier"
        case .precisionMultiplier: return "Option (precision)"
        case .scrollSpeed: return "Scroll speed"
        }
    }

    public var unit: String {
        switch self {
        case .holdThreshold, .acceleration: return "s"
        case .baseSpeed, .maxSpeed: return "pt/s"
        case .fastMultiplier, .fasterMultiplier, .precisionMultiplier: return "×"
        case .scrollSpeed: return "px"
        }
    }

    public var defaultValue: Double {
        switch self {
        case .holdThreshold: return 0.25
        case .baseSpeed: return 280
        case .maxSpeed: return 1400
        case .acceleration: return 0.45
        case .fastMultiplier: return 2.2
        case .fasterMultiplier: return 4.0
        case .precisionMultiplier: return 0.25
        case .scrollSpeed: return 8
        }
    }

    public var range: ClosedRange<Double> {
        switch self {
        case .holdThreshold: return 0.10...0.60
        case .baseSpeed: return 50...800
        case .maxSpeed: return 200...4000
        case .acceleration: return 0.05...2.0
        case .fastMultiplier: return 1.0...6.0
        case .fasterMultiplier: return 1.0...12.0
        case .precisionMultiplier: return 0.05...1.0
        case .scrollSpeed: return 1...40
        }
    }

    public func clamp(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// A resolved snapshot of the tunables, read once per engine event so the hot path
/// never touches UserDefaults.
public struct CursorSpeedProfile {
    public var baseSpeed: Double
    public var maxSpeed: Double
    public var acceleration: Double
    public var fastMultiplier: Double
    public var fasterMultiplier: Double
    public var precisionMultiplier: Double
    public var scrollSpeed: Double

    public init(
        baseSpeed: Double = CursorSetting.baseSpeed.defaultValue,
        maxSpeed: Double = CursorSetting.maxSpeed.defaultValue,
        acceleration: Double = CursorSetting.acceleration.defaultValue,
        fastMultiplier: Double = CursorSetting.fastMultiplier.defaultValue,
        fasterMultiplier: Double = CursorSetting.fasterMultiplier.defaultValue,
        precisionMultiplier: Double = CursorSetting.precisionMultiplier.defaultValue,
        scrollSpeed: Double = CursorSetting.scrollSpeed.defaultValue
    ) {
        self.baseSpeed = baseSpeed
        self.maxSpeed = maxSpeed
        self.acceleration = acceleration
        self.fastMultiplier = fastMultiplier
        self.fasterMultiplier = fasterMultiplier
        self.precisionMultiplier = precisionMultiplier
        self.scrollSpeed = scrollSpeed
    }
}

/// Speed tier selected by the modifiers held during cursor mode.
public struct SpeedTier: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = SpeedTier(rawValue: 1 << 0)
    public static let control = SpeedTier(rawValue: 1 << 1)
    public static let option = SpeedTier(rawValue: 1 << 2)

    /// Shift+Ctrl is the fastest tier, Shift alone the middle one. Option always wins
    /// so precision stays reachable without letting go of the other modifiers.
    public func multiplier(using profile: CursorSpeedProfile) -> Double {
        if contains(.option) { return profile.precisionMultiplier }
        if contains(.shift) && contains(.control) { return profile.fasterMultiplier }
        if contains(.shift) { return profile.fastMultiplier }
        return 1.0
    }
}

import Foundation

/// A HID++ 2.0 long report, the protocol Logitech mice speak over Bluetooth and through
/// their receivers.
///
/// Twenty bytes: report ID 0x11, the device index (0xFF for a mouse paired directly), the
/// index of a feature in the device's table, a function in the high nibble with a software
/// ID in the low one, and sixteen bytes of parameters. Answers carry the software ID of
/// the request back; notifications the device sends of its own accord carry zero.
public struct HIDPPMessage: Equatable, Sendable {
    public static let longReportID: UInt8 = 0x11
    public static let length = 20
    /// The device index of a mouse paired directly, not through a receiver.
    public static let directDevice: UInt8 = 0xFF
    /// Where an error answer puts its feature index.
    static let errorFeature: UInt8 = 0xFF

    public var deviceIndex: UInt8
    public var featureIndex: UInt8
    public var function: UInt8
    public var softwareID: UInt8
    public var parameters: [UInt8]

    public init(deviceIndex: UInt8, featureIndex: UInt8, function: UInt8, softwareID: UInt8, parameters: [UInt8] = []) {
        self.deviceIndex = deviceIndex
        self.featureIndex = featureIndex
        self.function = function & 0x0F
        self.softwareID = softwareID & 0x0F
        self.parameters = Array((parameters + Array(repeating: 0, count: 16)).prefix(16))
    }

    /// Reads a report as it arrived, report ID first. Nil for anything but a long report.
    public init?(report: [UInt8]) {
        guard report.count >= 4, report[0] == HIDPPMessage.longReportID else { return nil }
        self.init(
            deviceIndex: report[1],
            featureIndex: report[2],
            function: report[3] >> 4,
            softwareID: report[3] & 0x0F,
            parameters: Array(report.dropFirst(4))
        )
    }

    public var bytes: [UInt8] {
        [HIDPPMessage.longReportID, deviceIndex, featureIndex, function << 4 | softwareID] + parameters
    }

    /// Something the device sent of its own accord, not an answer.
    public var isNotification: Bool { softwareID == 0 && featureIndex != HIDPPMessage.errorFeature }

    /// For an error answer, the feature index and function of the request that failed and
    /// the error's code.
    public var error: (featureIndex: UInt8, function: UInt8, code: UInt8)? {
        guard featureIndex == HIDPPMessage.errorFeature else { return nil }
        // An error frame shifts everything along: its third byte is the failed request's
        // feature index and its fourth the request's function and software ID.
        return (function << 4 | softwareID, parameters[0] >> 4, parameters[1])
    }

    /// Whether this is the answer to `request`.
    public func answers(_ request: HIDPPMessage) -> Bool {
        if let error {
            return error.featureIndex == request.featureIndex && error.function == request.function
                && parameters[0] & 0x0F == request.softwareID
        }
        return deviceIndex == request.deviceIndex && featureIndex == request.featureIndex
            && function == request.function && softwareID == request.softwareID
    }
}

/// The root feature, always at index 0, which says where any other feature is.
public enum HIDPPRoot {
    public static let index: UInt8 = 0
    public static let getFeature: UInt8 = 0

    public static func findFeature(_ id: UInt16, device: UInt8, softwareID: UInt8) -> HIDPPMessage {
        HIDPPMessage(deviceIndex: device, featureIndex: index, function: getFeature, softwareID: softwareID,
                     parameters: [UInt8(id >> 8), UInt8(id & 0xFF)])
    }

    /// The feature's index in the device's table; nil when the device has no such feature.
    public static func featureIndex(from answer: HIDPPMessage) -> UInt8? {
        answer.parameters[0] == 0 ? nil : answer.parameters[0]
    }
}

/// REPROG_CONTROLS_V4, feature 0x1B04: the mouse's buttons, and handing one to software
/// instead of acting on it itself ("diverting" it).
public enum ReprogControls {
    public static let featureID: UInt16 = 0x1B04

    static let getCount: UInt8 = 0
    static let getControlInfo: UInt8 = 1
    static let setReporting: UInt8 = 3
    /// The notification, function 0, listing the diverted controls held down.
    static let divertedButtonsEvent: UInt8 = 0

    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }

        public static let mouseButton = Flags(rawValue: 0x01)
        public static let reprogrammable = Flags(rawValue: 0x10)
        public static let divertable = Flags(rawValue: 0x20)
        public static let persistentlyDivertable = Flags(rawValue: 0x40)
        public static let virtual = Flags(rawValue: 0x80)
        public static let rawXY = Flags(rawValue: 0x100)
    }

    public struct Control: Equatable, Sendable {
        public var id: UInt16
        public var taskID: UInt16
        public var flags: Flags

        public init(id: UInt16, taskID: UInt16, flags: Flags) {
            self.id = id
            self.taskID = taskID
            self.flags = flags
        }

        public static func == (lhs: Control, rhs: Control) -> Bool {
            lhs.id == rhs.id && lhs.taskID == rhs.taskID && lhs.flags.rawValue == rhs.flags.rawValue
        }
    }

    public static func countRequest(feature: UInt8, device: UInt8, softwareID: UInt8) -> HIDPPMessage {
        HIDPPMessage(deviceIndex: device, featureIndex: feature, function: getCount, softwareID: softwareID)
    }

    public static func controlRequest(at position: Int, feature: UInt8, device: UInt8, softwareID: UInt8) -> HIDPPMessage {
        HIDPPMessage(deviceIndex: device, featureIndex: feature, function: getControlInfo, softwareID: softwareID,
                     parameters: [UInt8(position)])
    }

    /// Diverts `control`, or gives it back to the mouse. Never persistently: a mouse that
    /// loses its connection, or outlives a crash, comes back as it was.
    public static func divertRequest(_ control: UInt16, divert: Bool, feature: UInt8, device: UInt8, softwareID: UInt8) -> HIDPPMessage {
        // Bit 0 diverts and bit 1 says bit 0 is meant.
        HIDPPMessage(deviceIndex: device, featureIndex: feature, function: setReporting, softwareID: softwareID,
                     parameters: [UInt8(control >> 8), UInt8(control & 0xFF), divert ? 0x03 : 0x02, 0, 0])
    }

    public static func count(from answer: HIDPPMessage) -> Int {
        Int(answer.parameters[0])
    }

    public static func control(from answer: HIDPPMessage) -> Control {
        let p = answer.parameters
        return Control(
            id: UInt16(p[0]) << 8 | UInt16(p[1]),
            taskID: UInt16(p[2]) << 8 | UInt16(p[3]),
            // The low byte of the flags, then position, group and group mask, then the high byte.
            flags: Flags(rawValue: UInt16(p[4]) | UInt16(p[8]) << 8)
        )
    }

    /// The diverted controls held down, from the notification the mouse sends whenever that
    /// changes; nil for any other message.
    public static func pressedControls(in message: HIDPPMessage, feature: UInt8) -> [UInt16]? {
        guard message.isNotification, message.featureIndex == feature, message.function == divertedButtonsEvent else {
            return nil
        }
        var pressed: [UInt16] = []
        for slot in 0..<4 {
            let id = UInt16(message.parameters[slot * 2]) << 8 | UInt16(message.parameters[slot * 2 + 1])
            if id == 0 { break }
            pressed.append(id)
        }
        return pressed
    }
}

/// Finds a mouse's REPROG_CONTROLS_V4 and lists its controls, one request at a time.
public struct HIDPPDiscovery: Sendable {
    public enum Outcome: Equatable, Sendable {
        case send(HIDPPMessage)
        case ready(feature: UInt8, controls: [ReprogControls.Control])
        case failed(String)
    }

    private enum Step: Sendable {
        case feature
        case count(feature: UInt8)
        case control(feature: UInt8, position: Int, of: Int)
        case done
    }

    public let device: UInt8
    public let softwareID: UInt8
    private var step = Step.feature
    private var controls: [ReprogControls.Control] = []
    private(set) public var pending: HIDPPMessage?

    public init(device: UInt8 = HIDPPMessage.directDevice, softwareID: UInt8 = 0x0A) {
        self.device = device
        self.softwareID = softwareID
    }

    public mutating func start() -> Outcome {
        step = .feature
        controls = []
        return send(HIDPPRoot.findFeature(ReprogControls.featureID, device: device, softwareID: softwareID))
    }

    /// Takes in a message from the device. Nil when it is not the answer being waited for.
    public mutating func receive(_ message: HIDPPMessage) -> Outcome? {
        guard let pending, message.answers(pending) else { return nil }
        if let error = message.error {
            step = .done
            self.pending = nil
            return .failed(String(format: "the mouse answered with error %d", error.code))
        }
        switch step {
        case .feature:
            guard let feature = HIDPPRoot.featureIndex(from: message) else {
                step = .done
                self.pending = nil
                return .failed("the mouse has no reprogrammable controls")
            }
            step = .count(feature: feature)
            return send(ReprogControls.countRequest(feature: feature, device: device, softwareID: softwareID))
        case .count(let feature):
            let count = ReprogControls.count(from: message)
            return next(feature: feature, position: 0, of: count)
        case .control(let feature, let position, let count):
            controls.append(ReprogControls.control(from: message))
            return next(feature: feature, position: position + 1, of: count)
        case .done:
            return nil
        }
    }

    private mutating func next(feature: UInt8, position: Int, of count: Int) -> Outcome {
        guard position < count else {
            step = .done
            pending = nil
            return .ready(feature: feature, controls: controls)
        }
        step = .control(feature: feature, position: position, of: count)
        return send(ReprogControls.controlRequest(at: position, feature: feature, device: device, softwareID: softwareID))
    }

    private mutating func send(_ message: HIDPPMessage) -> Outcome {
        pending = message
        return .send(message)
    }
}

/// Turns the mouse's list of diverted controls held down into presses and releases.
public struct DivertedButtonDiff: Equatable, Sendable {
    private var held: [UInt16] = []

    public init() {}

    public mutating func update(_ pressed: [UInt16]) -> (pressed: [UInt16], released: [UInt16]) {
        let newlyPressed = pressed.filter { !held.contains($0) }
        let released = held.filter { !pressed.contains($0) }
        held = pressed
        return (newlyPressed, released)
    }

    /// Everything held, released, for when the mouse goes away or is given back.
    public mutating func releaseAll() -> [UInt16] {
        defer { held = [] }
        return held
    }
}

/// The Logitech controls MouseNavigate binds like side buttons, numbered past the 32
/// buttons CoreGraphics has, so their bindings are stored as any button's are.
public enum LogitechControl: UInt16, CaseIterable, Sendable {
    /// The gesture button under the thumb.
    case gestureButton = 0x00C3
    /// The button behind the wheel that switches it between ratchet and free spin.
    case modeShift = 0x00C4
    /// The MX Master 4's haptic panel above the thumb.
    case hapticPanel = 0x01A0

    public static let firstButton = 32

    public var button: Int {
        switch self {
        case .gestureButton: return 32
        case .modeShift: return 33
        case .hapticPanel: return 34
        }
    }

    public var displayName: String {
        switch self {
        case .gestureButton: return "Gesture button"
        case .modeShift: return "Mode shift button"
        case .hapticPanel: return "Haptic panel"
        }
    }

    public init?(button: Int) {
        guard let control = LogitechControl.allCases.first(where: { $0.button == button }) else { return nil }
        self = control
    }

    public static func isVirtual(button: Int) -> Bool {
        button >= firstButton
    }

    /// The controls a mouse model has that can be bound.
    public static func controls(for profile: DeviceProfile) -> [LogitechControl] {
        switch profile {
        case .mxMaster4: return [.gestureButton, .hapticPanel, .modeShift]
        case .mxMaster3: return [.gestureButton, .modeShift]
        case .generic: return []
        }
    }
}

import Foundation
import IOKit
import IOKit.hid
import MouseNavigateCore

/// Takes the Logitech controls that have bindings — the gesture button, the haptic panel,
/// the mode shift button — from the mouse over HID++, and reports their presses and
/// releases as buttons numbered from 32, for the button pipeline to treat like any other.
///
/// A control is only taken while it has a binding and MouseNavigate is not standing down;
/// the rest go on doing what the mouse does with them, and a mouse with nothing bound is
/// never even opened. Taking one is never persistent, so a mouse that reconnects, or
/// outlives a crash, comes back as it was; it is taken again when it reconnects, after
/// waking and when the settings change, and given back on quit. Only a mouse paired
/// directly over Bluetooth is reached for now, not one on a receiver.
@MainActor
final class LogitechControlMonitor {
    /// Called with the control's button number.
    var onPress: ((Int) -> Void)?
    var onRelease: ((Int) -> Void)?

    /// Standing down, as when paused: every control is given back.
    var isPaused = false {
        didSet {
            if isPaused != oldValue { refresh() }
        }
    }

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var watcher: IOServiceWatcher?
    private var sessions: [UInt64: LogitechDeviceSession] = [:]

    func start() {
        // The HID++ channel of a mouse paired directly, by its vendor-defined collection.
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: DeviceMatcher.logitechVendorID,
            kIOHIDDeviceUsagePageKey: 0xFF43,
            kIOHIDDeviceUsageKey: 0x0202,
        ] as CFDictionary)
        watcher = IOServiceWatcher(serviceClass: kIOHIDDeviceKey) { [weak self] in
            self?.refresh()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesDidChange(_:)),
            name: Preferences.didChangeNotification,
            object: nil
        )
        refresh()
    }

    /// Takes again what should be taken, for after waking: a mouse that slept may have
    /// given everything back by itself.
    func retake() {
        for session in sessions.values {
            session.forgetDiverted()
        }
        refresh()
    }

    /// Gives every control back, for quitting.
    func stop() {
        for session in sessions.values {
            release(session.close())
        }
        sessions.removeAll()
    }

    @objc private func preferencesDidChange(_ notification: Notification) {
        switch notification.settingsArea {
        case .bindings, .apps, .device, .all:
            refresh()
        default:
            break
        }
    }

    private func refresh() {
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        var present: Set<UInt64> = []
        for device in devices {
            let id = Self.registryID(of: device)
            present.insert(id)
            let profile = Preferences.shared.deviceOverride ?? Self.profile(of: device) ?? .generic
            let wanted = isPaused ? [] : Preferences.shared.boundLogitechControls(profile: profile)

            if let session = sessions[id] {
                session.wanted = Set(wanted.map(\.rawValue))
            } else if !wanted.isEmpty {
                let session = LogitechDeviceSession(device: device, name: Self.name(of: device))
                session.onPressed = { [weak self] control in
                    self?.onPress?(control.button)
                }
                session.onReleased = { [weak self] control in
                    self?.onRelease?(control.button)
                }
                session.wanted = Set(wanted.map(\.rawValue))
                if session.open() {
                    sessions[id] = session
                }
            }
        }
        // A mouse that went away gives back what it was holding down.
        for (id, session) in sessions where !present.contains(id) {
            release(session.close())
            sessions[id] = nil
        }
        // A mouse with nothing left to take is let go.
        for (id, session) in sessions where session.wanted.isEmpty && session.isSettled {
            release(session.close())
            sessions[id] = nil
        }
    }

    private func release(_ controls: [LogitechControl]) {
        for control in controls {
            onRelease?(control.button)
        }
    }

    private static func registryID(of device: IOHIDDevice) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
        return id
    }

    private static func name(of device: IOHIDDevice) -> String {
        IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "a Logitech mouse"
    }

    private static func profile(of device: IOHIDDevice) -> DeviceProfile? {
        DeviceMatcher.match(
            vendorID: (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue ?? 0,
            productID: (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue ?? 0,
            productName: name(of: device)
        )
    }
}

/// One mouse's HID++ conversation: finding its controls, then taking and giving back the
/// ones wanted, one request at a time, and hearing which are held down.
@MainActor
private final class LogitechDeviceSession {
    private static let requestTimeout: TimeInterval = 1
    private nonisolated static let reportSize = 64

    let device: IOHIDDevice
    let name: String
    var onPressed: ((LogitechControl) -> Void)?
    var onReleased: ((LogitechControl) -> Void)?

    /// The controls to take, by control ID.
    var wanted: Set<UInt16> = [] {
        didSet { sync() }
    }

    private var discovery = HIDPPDiscovery()
    private var feature: UInt8?
    private var divertable: Set<UInt16> = []
    private var diverted: Set<UInt16> = []
    private var held = DivertedButtonDiff()
    /// Requests waiting their turn, and the one sent and not yet answered.
    private var queue: [HIDPPMessage] = []
    private var inFlight: HIDPPMessage?
    private var timeout: MainTimer?
    private var isOpen = false
    /// Where IOKit puts each report; only freed in deinit, once nothing can write to it.
    nonisolated(unsafe) private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportSize)

    init(device: IOHIDDevice, name: String) {
        self.device = device
        self.name = name
    }

    deinit {
        buffer.deallocate()
    }

    /// Nothing under way: found, and taken or given back as wanted.
    var isSettled: Bool { feature != nil && inFlight == nil && queue.isEmpty }

    func open() -> Bool {
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            Log.devices.error(
                "\(self.name, privacy: .public) could not be opened for its buttons: \(String(format: "0x%08X", result), privacy: .public)."
            )
            return false
        }
        isOpen = true
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, Self.reportSize, { context, _, _, _, _, report, length in
            guard let context else { return }
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            // Scheduled on the main run loop below.
            MainActor.assumeIsolated {
                Unmanaged<LogitechDeviceSession>.fromOpaque(context).takeUnretainedValue().received(bytes)
            }
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        if case .send(let first) = discovery.start() {
            send(first)
        }
        return true
    }

    /// Gives back what was taken and closes the device. Returns what was held down, for its
    /// releases to go out.
    func close() -> [LogitechControl] {
        guard isOpen else { return [] }
        for control in diverted {
            write(ReprogControls.divertRequest(control, divert: false, feature: feature ?? 0, device: discovery.device, softwareID: discovery.softwareID))
        }
        if !diverted.isEmpty {
            Log.devices.info("Gave \(self.name, privacy: .public)'s buttons back.")
        }
        diverted.removeAll()
        timeout = nil
        IOHIDDeviceRegisterInputReportCallback(device, buffer, Self.reportSize, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        isOpen = false
        return held.releaseAll().compactMap(LogitechControl.init(rawValue:))
    }

    /// The mouse may have given everything back by itself, as after sleeping.
    func forgetDiverted() {
        diverted.removeAll()
    }

    // MARK: - Messages

    private func received(_ bytes: [UInt8]) {
        guard let message = HIDPPMessage(report: bytes) else { return }

        if let feature, let pressed = ReprogControls.pressedControls(in: message, feature: feature) {
            let change = held.update(pressed)
            for id in change.released { LogitechControl(rawValue: id).map { onReleased?($0) } }
            for id in change.pressed { LogitechControl(rawValue: id).map { onPressed?($0) } }
            return
        }

        guard let inFlight, message.answers(inFlight) else { return }
        self.inFlight = nil
        timeout = nil

        if feature == nil {
            switch discovery.receive(message) {
            case .send(let next)?:
                send(next)
                return
            case .ready(let found, let controls)?:
                feature = found
                divertable = Set(controls.filter { $0.flags.contains(.divertable) }.map(\.id))
                sync()
            case .failed(let reason)?:
                Log.devices.notice("\(self.name, privacy: .public)'s buttons cannot be taken: \(reason, privacy: .public).")
            case nil:
                break
            }
        } else if let error = message.error {
            Log.devices.notice("\(self.name, privacy: .public) refused a button change: error \(error.code).")
        }
        sendNext()
    }

    /// Queues what it takes to have taken exactly what is wanted.
    private func sync() {
        guard let feature else { return }
        let target = wanted.intersection(divertable)
        for control in target.subtracting(diverted).sorted() {
            queue.append(ReprogControls.divertRequest(control, divert: true, feature: feature, device: discovery.device, softwareID: discovery.softwareID))
        }
        for control in diverted.subtracting(target).sorted() {
            queue.append(ReprogControls.divertRequest(control, divert: false, feature: feature, device: discovery.device, softwareID: discovery.softwareID))
        }
        if target != diverted {
            let names = target.compactMap(LogitechControl.init(rawValue:)).map(\.displayName).sorted()
            Log.devices.info(
                "Taking \(names.isEmpty ? "none" : names.joined(separator: ", "), privacy: .public) of \(self.name, privacy: .public)'s buttons."
            )
        }
        diverted = target
        sendNext()
    }

    private func sendNext() {
        guard inFlight == nil, !queue.isEmpty else { return }
        send(queue.removeFirst())
    }

    private func send(_ message: HIDPPMessage) {
        guard write(message) else { return }
        inFlight = message
        timeout = MainTimer(after: Self.requestTimeout) { [weak self] in
            guard let self else { return }
            Log.devices.notice("\(self.name, privacy: .public) did not answer; leaving its buttons as they are.")
            self.inFlight = nil
            self.queue.removeAll()
        }
    }

    @discardableResult
    private func write(_ message: HIDPPMessage) -> Bool {
        let bytes = message.bytes
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(HIDPPMessage.longReportID), bytes, bytes.count)
        if result != kIOReturnSuccess {
            Log.devices.error("Could not reach \(self.name, privacy: .public): \(String(format: "0x%08X", result), privacy: .public).")
        }
        return result == kIOReturnSuccess
    }
}

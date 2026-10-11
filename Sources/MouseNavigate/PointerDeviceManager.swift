import AppKit
import IOKit.hid
import IOKit.hidsystem
import MouseNavigateCore

/// Sets each mouse's pointer speed and acceleration, where macOS keeps them for it.
///
/// They live on the mouse's HID service, beside the Tracking speed System Settings puts
/// there, so they last only while the mouse stays connected and until System Settings
/// writes its own again. So they are set whenever a mouse arrives, after waking, when the
/// settings change, and every few seconds while any mouse has settings of its own. A mouse
/// going back to standard, and every mouse on quit, is put back as System Settings has it.
/// Trackpads, keyboards and built-in devices are never touched.
@MainActor
final class PointerDeviceManager {
    private static let resolutionKey = kIOHIDPointerResolutionKey as String
    private static let accelerationTypeKey = "HIDPointerAccelerationType"
    private static let mouseAccelerationKey = "HIDMouseAcceleration"
    /// How often the values are checked while any mouse has its own, since System Settings
    /// says nothing when it puts its own back.
    private static let recheckInterval: TimeInterval = 5

    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private var watcher: IOServiceWatcher?
    private var recheckTimer: MainTimer?
    /// Services this run has changed, by registry ID, so they can be put back.
    private var changed: Set<UInt64> = []

    func start() {
        watcher = IOServiceWatcher(serviceClass: kIOHIDDeviceKey) { [weak self] in
            self?.apply()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesDidChange(_:)),
            name: Preferences.didChangeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        apply()
    }

    /// Every mouse back as System Settings has it, for quitting.
    func restoreAll() {
        for service in mouseServices() where changed.contains(registryID(of: service)) {
            restore(service)
        }
        changed.removeAll()
        recheckTimer = nil
    }

    @objc private func preferencesDidChange(_ notification: Notification) {
        switch notification.settingsArea {
        case .pointer, .device, .all:
            apply()
        default:
            break
        }
    }

    @objc private func didWake() {
        watcher?.poke()
    }

    /// The Tracking speed System Settings has, which the system's own acceleration is.
    private var systemAcceleration: Double {
        (UserDefaults.standard.object(forKey: "com.apple.mouse.scaling") as? NSNumber)?.doubleValue
            ?? PointerMath.defaultSystemAcceleration
    }

    private func apply() {
        let preferences = Preferences.shared
        guard preferences.isAnyPointerSettingActive || !changed.isEmpty else {
            recheckTimer = nil
            return
        }

        var present: Set<UInt64> = []
        for service in mouseServices() {
            let id = registryID(of: service)
            present.insert(id)
            let profile = preferences.deviceOverride ?? match(service) ?? .generic
            let settings = preferences.resolvedPointerSettings(profile: profile)
            if settings.isActive {
                set(settings, on: service)
                changed.insert(id)
            } else if changed.contains(id) {
                restore(service)
                changed.remove(id)
            }
        }
        // A mouse that went away takes its values with it.
        changed.formIntersection(present)

        if preferences.isAnyPointerSettingActive {
            if recheckTimer == nil {
                recheckTimer = MainTimer(after: Self.recheckInterval, repeating: Self.recheckInterval) { [weak self] in
                    self?.apply()
                }
            }
        } else {
            recheckTimer = nil
        }
    }

    private func set(_ settings: PointerSettings, on service: IOHIDServiceClient) {
        write(PointerMath.resolution(speed: settings.speed), to: Self.resolutionKey, of: service)
        write(
            PointerMath.acceleration(for: settings, systemAcceleration: systemAcceleration),
            to: accelerationKey(of: service),
            of: service
        )
    }

    private func restore(_ service: IOHIDServiceClient) {
        write(PointerMath.resolution(speed: 1), to: Self.resolutionKey, of: service)
        write(PointerMath.fixed(systemAcceleration), to: accelerationKey(of: service), of: service)
    }

    /// Only when it differs: each write is a trip to the HID system, and System Settings
    /// shows nothing for an unchanged value either.
    private func write(_ value: Int, to key: String, of service: IOHIDServiceClient) {
        let current = (IOHIDServiceClientCopyProperty(service, key as CFString) as? NSNumber)?.intValue
        guard current != value else { return }
        if IOHIDServiceClientSetProperty(service, key as CFString, NSNumber(value: value)) {
            Log.devices.info(
                "\(key, privacy: .public) of \(self.name(of: service), privacy: .public) set to \(value)."
            )
        } else {
            Log.devices.error(
                "\(key, privacy: .public) of \(self.name(of: service), privacy: .public) could not be set."
            )
        }
    }

    // MARK: - Services

    /// The external mice, as the HID system has them.
    private func mouseServices() -> [IOHIDServiceClient] {
        guard let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else { return [] }
        return services.filter { service in
            IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse)) != 0
                && DeviceMatcher.isMouseCandidate(info(of: service))
        }
    }

    private func info(of service: IOHIDServiceClient) -> HIDDeviceInfo {
        HIDDeviceInfo(
            vendorID: number(kIOHIDVendorIDKey, of: service) ?? 0,
            productID: number(kIOHIDProductIDKey, of: service) ?? 0,
            productName: IOHIDServiceClientCopyProperty(service, kIOHIDProductKey as CFString) as? String,
            isBuiltIn: (number(kIOHIDBuiltInKey, of: service) ?? 0) != 0
        )
    }

    private func match(_ service: IOHIDServiceClient) -> DeviceProfile? {
        let info = info(of: service)
        return DeviceMatcher.match(vendorID: info.vendorID, productID: info.productID, productName: info.productName)
    }

    private func name(of service: IOHIDServiceClient) -> String {
        info(of: service).productName ?? "a mouse"
    }

    /// The key this mouse keeps its acceleration under, which it says itself.
    private func accelerationKey(of service: IOHIDServiceClient) -> String {
        IOHIDServiceClientCopyProperty(service, Self.accelerationTypeKey as CFString) as? String
            ?? Self.mouseAccelerationKey
    }

    private func number(_ key: String, of service: IOHIDServiceClient) -> Int? {
        (IOHIDServiceClientCopyProperty(service, key as CFString) as? NSNumber)?.intValue
    }

    private func registryID(of service: IOHIDServiceClient) -> UInt64 {
        (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value ?? 0
    }
}

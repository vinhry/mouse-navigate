import AppKit
import Foundation
import IOKit
import IOKit.hid
import MouseNavigateCore

/// Identifies the attached pointing device so its button profile can be selected.
///
/// Devices are only enumerated, never opened: reading vendor/product properties needs
/// no Input Monitoring grant, whereas `IOHIDManagerOpen` would.
final class DeviceDetector {
    static let didChangeNotification = Notification.Name("com.vinhry.MouseNavigate.deviceDidChange")

    private let manager: IOHIDManager
    private var refreshTimer: Timer?

    private(set) var detectedProfile: DeviceProfile?
    private(set) var detectedName: String?

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let matching: [[String: Any]] = [
            [
                kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Mouse,
            ],
            [
                kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Pointer,
            ],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
    }

    deinit {
        refreshTimer?.invalidate()
    }

    func start() {
        refresh()

        // Bluetooth mice come and go without any event we can cheaply subscribe to,
        // so a slow poll plus a wake hook keeps the profile current.
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func handleWake() {
        refresh()
    }

    /// The profile actually in force, honouring a manual override from preferences.
    var activeProfile: DeviceProfile {
        Preferences.shared.deviceOverride ?? detectedProfile ?? .generic
    }

    /// Human-readable summary for the preferences window.
    var statusDescription: String {
        if let override = Preferences.shared.deviceOverride {
            return "\(override.displayName) — set manually"
        }
        guard let detectedProfile else {
            return "No mouse detected — using \(DeviceProfile.generic.displayName)"
        }
        if let detectedName, !detectedName.isEmpty {
            return "\(detectedName) — detected"
        }
        return "\(detectedProfile.displayName) — detected"
    }

    @discardableResult
    func refresh() -> DeviceProfile? {
        let devices = enumerateDevices()
        let profile = DeviceMatcher.bestProfile(from: devices)

        let name = devices.first(where: {
            DeviceMatcher.match(
                vendorID: $0.vendorID,
                productID: $0.productID,
                productName: $0.productName
            ) != nil
        })?.productName ?? devices.first?.productName

        let changed = profile != detectedProfile || name != detectedName
        detectedProfile = profile
        detectedName = name

        if changed {
            NotificationCenter.default.post(name: DeviceDetector.didChangeNotification, object: nil)
        }
        return profile
    }

    /// One line per attached pointing device, for the --list-devices diagnostic.
    func deviceSummaries() -> [String] {
        enumerateDevices().map { device in
            let name = device.productName ?? "(unnamed)"
            let profile = DeviceMatcher.match(
                vendorID: device.vendorID,
                productID: device.productID,
                productName: device.productName
            )
            let resolved = profile.map { $0.displayName } ?? "unrecognised"
            return String(
                format: "%@ [vendor 0x%04X, product 0x%04X] -> %@",
                name, device.vendorID, device.productID, resolved
            )
        }
    }

    private func enumerateDevices() -> [(vendorID: Int, productID: Int, productName: String?)] {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return []
        }

        return devices.map { device in
            (
                vendorID: intProperty(device, kIOHIDVendorIDKey) ?? 0,
                productID: intProperty(device, kIOHIDProductIDKey) ?? 0,
                productName: IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
            )
        }
        // Stable ordering keeps the reported device from flapping between refreshes.
        .sorted { ($0.productName ?? "") < ($1.productName ?? "") }
    }

    private func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }
}

import Foundation

/// A mouse model whose button layout gets its own saved mapping.
public enum DeviceProfile: String, CaseIterable {
    case mxMaster4 = "mxMaster4"
    case mxMaster3 = "mxMaster3"
    case generic = "generic"

    public var displayName: String {
        switch self {
        case .mxMaster4: return "Logitech MX Master 4"
        case .mxMaster3: return "Logitech MX Master 3"
        case .generic: return "Generic Mouse"
        }
    }

    /// Buttons pre-mapped for a freshly installed profile.
    public var defaultActions: [Int: ButtonAction] {
        switch self {
        case .mxMaster4:
            return [3: .back, 4: .forward, 5: .appExpose, 6: .missionControl]
        case .mxMaster3, .generic:
            // Only the two side buttons are consistent across these; the rest is
            // left for the user to discover with the button tester.
            return [3: .back, 4: .forward]
        }
    }
}

public enum DeviceMatcher {
    public static let logitechVendorID = 0x046D

    /// Product IDs seen for each model. The same mouse reports a different ID over
    /// Bluetooth, a Bolt receiver and a Unifying receiver, so this is only a fallback
    /// for when the product string is missing or unrecognised.
    private static let productIDs: [Int: DeviceProfile] = [
        0xB042: .mxMaster4,  // Bluetooth LE
        0xB023: .mxMaster3,  // Bluetooth LE
        0xB034: .mxMaster3,  // MX Master 3S, Bluetooth LE
        0x4082: .mxMaster3,  // Unifying receiver
        0xB035: .mxMaster3,  // MX Master 3S for Mac, Bluetooth LE
    ]

    /// Identify a single HID device. Returns nil when it is not a mouse we know how to
    /// profile, so callers can keep looking through the remaining devices.
    public static func match(vendorID: Int, productID: Int, productName: String?) -> DeviceProfile? {
        if let profile = matchProductName(productName) {
            return profile
        }

        guard vendorID == logitechVendorID else { return nil }
        return productIDs[productID]
    }

    /// The product string is the most reliable signal: it stays stable across transports.
    static func matchProductName(_ productName: String?) -> DeviceProfile? {
        guard let normalized = normalize(productName) else { return nil }

        if normalized.contains("mx master 4") { return .mxMaster4 }
        // Also covers "mx master 3s" and "mx master 3b".
        if normalized.contains("mx master 3") { return .mxMaster3 }
        return nil
    }

    /// Lowercase, collapse runs of whitespace, and drop the marketing prefix Logitech
    /// uses on receiver-attached devices ("Wireless Mouse MX Master 3").
    static func normalize(_ productName: String?) -> String? {
        guard let productName else { return nil }

        let lowercased = productName.lowercased()
        let collapsed = lowercased
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }

        for prefix in ["wireless mouse ", "logitech ", "logi "] where collapsed.hasPrefix(prefix) {
            return String(collapsed.dropFirst(prefix.count))
        }
        return collapsed
    }

    /// Pick one profile from every attached pointing device. A recognised model always
    /// wins over an unrecognised one.
    public static func bestProfile(
        from devices: [(vendorID: Int, productID: Int, productName: String?)]
    ) -> DeviceProfile? {
        for device in devices {
            if let profile = match(
                vendorID: device.vendorID,
                productID: device.productID,
                productName: device.productName
            ) {
                return profile
            }
        }
        return devices.isEmpty ? nil : .generic
    }
}

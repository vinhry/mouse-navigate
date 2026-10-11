import Foundation
import MouseNavigateCore

extension MacOSTrackpadSettings {
    /// System Settings writes the built-in trackpad's domain and the Bluetooth trackpad's
    /// alike; the first that has a key answers for it.
    private static let domains = [
        "com.apple.AppleMultitouchTrackpad",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad",
    ]

    /// The macOS trackpad settings as they are now. Synchronised first, so a change made
    /// in System Settings a moment ago is seen.
    static func current() -> MacOSTrackpadSettings {
        var values: [MacOSTrackpadGesture: Int] = [:]
        for domain in domains {
            CFPreferencesAppSynchronize(domain as CFString)
        }
        for gesture in MacOSTrackpadGesture.allCases {
            for domain in domains {
                if let value = CFPreferencesCopyAppValue(gesture.defaultsKey as CFString, domain as CFString) as? Int {
                    values[gesture] = value
                    break
                }
            }
        }
        return MacOSTrackpadSettings(values: values)
    }
}

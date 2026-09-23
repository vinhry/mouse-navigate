import XCTest
@testable import MouseNavigateCore

final class DeviceProfileTests: XCTestCase {
    func testMatchesMXMaster4ByProductString() {
        // Values observed from a real MX Master 4 over Bluetooth LE.
        XCTAssertEqual(
            DeviceMatcher.match(vendorID: 0x046D, productID: 0xB042, productName: "MX Master 4"),
            .mxMaster4
        )
    }

    func testMatchesMXMaster3Variants() {
        for name in ["MX Master 3", "MX Master 3S", "MX Master 3B", "mx master 3s for mac"] {
            XCTAssertEqual(
                DeviceMatcher.match(vendorID: 0x046D, productID: 0, productName: name),
                .mxMaster3,
                "expected \(name) to match MX Master 3"
            )
        }
    }

    func testStripsReceiverProductPrefix() {
        XCTAssertEqual(
            DeviceMatcher.match(vendorID: 0x046D, productID: 0, productName: "Wireless Mouse MX Master 3"),
            .mxMaster3
        )
    }

    func testFallsBackToProductIDWhenNameIsMissing() {
        XCTAssertEqual(
            DeviceMatcher.match(vendorID: 0x046D, productID: 0xB042, productName: nil),
            .mxMaster4
        )
        XCTAssertEqual(
            DeviceMatcher.match(vendorID: 0x046D, productID: 0x4082, productName: nil),
            .mxMaster3
        )
    }

    func testIgnoresProductIDFromOtherVendors() {
        // Another vendor reusing the same product ID must not be mistaken for Logitech.
        XCTAssertNil(DeviceMatcher.match(vendorID: 0x1234, productID: 0xB042, productName: "Some Mouse"))
    }

    func testUnknownDeviceDoesNotMatch() {
        XCTAssertNil(
            DeviceMatcher.match(vendorID: 0x046D, productID: 0x0001, productName: "MX Anywhere 2")
        )
    }

    func testBestProfilePrefersRecognisedDevice() {
        let devices = [
            HIDDeviceInfo(vendorID: 0x046D, productID: 0x0001, productName: "MX Anywhere 2"),
            HIDDeviceInfo(vendorID: 0x046D, productID: 0xB042, productName: "MX Master 4"),
        ]
        XCTAssertEqual(DeviceMatcher.bestProfile(from: devices), .mxMaster4)
    }

    func testBestProfileFallsBackToGenericForAnUnknownMouse() {
        let devices = [HIDDeviceInfo(vendorID: 0x004C, productID: 0x0269, productName: "Magic Mouse")]
        XCTAssertEqual(DeviceMatcher.bestProfile(from: devices), .generic)
    }

    func testBestProfileIsNilWithNoDevices() {
        XCTAssertNil(DeviceMatcher.bestProfile(from: []))
    }

    func testBuiltInKeyboardAndTrackpadIsNotAMouse() {
        // Observed on an Apple silicon MacBook: vendor and product are both 0.
        let devices = [
            HIDDeviceInfo(vendorID: 0, productID: 0, productName: "Apple Internal Keyboard / Trackpad", isBuiltIn: true)
        ]
        XCTAssertNil(DeviceMatcher.bestProfile(from: devices))
    }

    func testBuiltInFlagAloneExcludesADevice() {
        let device = HIDDeviceInfo(vendorID: 0, productID: 0, productName: nil, isBuiltIn: true)
        XCTAssertFalse(DeviceMatcher.isMouseCandidate(device))
    }

    func testExternalTrackpadIsNotAMouse() {
        let devices = [HIDDeviceInfo(vendorID: 0x004C, productID: 0x0265, productName: "Magic Trackpad")]
        XCTAssertNil(DeviceMatcher.bestProfile(from: devices))
    }

    func testExternalKeyboardIsNotAMouse() {
        let devices = [HIDDeviceInfo(vendorID: 0x004C, productID: 0x029C, productName: "Magic Keyboard with Touch ID")]
        XCTAssertNil(DeviceMatcher.bestProfile(from: devices))
    }

    func testRecognisedMouseWinsBesideTheBuiltInTrackpad() {
        let devices = [
            HIDDeviceInfo(vendorID: 0, productID: 0, productName: "Apple Internal Keyboard / Trackpad", isBuiltIn: true),
            HIDDeviceInfo(vendorID: 0x046D, productID: 0xB042, productName: "MX Master 4"),
        ]
        XCTAssertEqual(DeviceMatcher.bestProfile(from: devices), .mxMaster4)
    }

    func testDefaultActionsPerProfile() {
        XCTAssertEqual(DeviceProfile.mxMaster4.defaultActions[5], .appExpose)
        XCTAssertEqual(DeviceProfile.mxMaster4.defaultActions[6], .missionControl)
        // MX Master 3's extra buttons are left unmapped rather than guessed at.
        XCTAssertNil(DeviceProfile.mxMaster3.defaultActions[5])
        XCTAssertEqual(DeviceProfile.mxMaster3.defaultActions[3], .back)
    }
}

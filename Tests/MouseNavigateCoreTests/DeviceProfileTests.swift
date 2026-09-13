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
        let devices: [(vendorID: Int, productID: Int, productName: String?)] = [
            (0x05AC, 0x0001, "Apple Internal Keyboard / Trackpad"),
            (0x046D, 0xB042, "MX Master 4"),
        ]
        XCTAssertEqual(DeviceMatcher.bestProfile(from: devices), .mxMaster4)
    }

    func testBestProfileFallsBackToGenericWhenSomethingIsAttached() {
        let devices: [(vendorID: Int, productID: Int, productName: String?)] = [
            (0x05AC, 0x0001, "Apple Internal Keyboard / Trackpad")
        ]
        XCTAssertEqual(DeviceMatcher.bestProfile(from: devices), .generic)
    }

    func testBestProfileIsNilWithNoDevices() {
        XCTAssertNil(DeviceMatcher.bestProfile(from: []))
    }

    func testDefaultActionsPerProfile() {
        XCTAssertEqual(DeviceProfile.mxMaster4.defaultActions[5], .appExpose)
        XCTAssertEqual(DeviceProfile.mxMaster4.defaultActions[6], .missionControl)
        // MX Master 3's extra buttons are left unmapped rather than guessed at.
        XCTAssertNil(DeviceProfile.mxMaster3.defaultActions[5])
        XCTAssertEqual(DeviceProfile.mxMaster3.defaultActions[3], .back)
    }
}

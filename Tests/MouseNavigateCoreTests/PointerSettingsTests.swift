import XCTest
@testable import MouseNavigateCore

final class PointerSettingsTests: XCTestCase {
    func testStandardLeavesThePointerAlone() {
        XCTAssertFalse(PointerSettings.standard.isActive)
        XCTAssertTrue(PointerSettings(speed: 2).isActive)
        XCTAssertTrue(PointerSettings(accelerationMode: .off).isActive)
        XCTAssertFalse(PointerSettings(acceleration: 2).isActive, "a custom curve only counts once chosen")
    }

    func testValuesAreKeptInRange() {
        XCTAssertEqual(PointerSettings(speed: 10).speed, 4)
        XCTAssertEqual(PointerSettings(speed: 0).speed, 0.25)
        XCTAssertEqual(PointerSettings(acceleration: -1).acceleration, 0)
        XCTAssertEqual(PointerOverride(speed: 9).speed, 4)
    }

    func testAnOverrideFollowsWhatItLeavesUnset() {
        let base = PointerSettings(speed: 2, accelerationMode: .custom, acceleration: 1.5)
        XCTAssertEqual(PointerOverride(accelerationMode: .off).applied(to: base),
                       PointerSettings(speed: 2, accelerationMode: .off, acceleration: 1.5))
        XCTAssertEqual(PointerOverride.none.applied(to: base), base)
    }

    func testFieldsRoundTripThroughPropertyLists() {
        let override = PointerOverride(speed: 1.5, accelerationMode: .custom, acceleration: 2)
        var copy = PointerOverride()
        for field in PointerField.allCases {
            copy.set(field, to: override.value(of: field))
        }
        XCTAssertEqual(copy, override)

        var wrong = PointerOverride()
        wrong.set(.speed, to: true)
        wrong.set(.accelerationMode, to: "sideways")
        XCTAssertEqual(wrong, .none, "values of the wrong kind stay unset")
    }

    func testKeysAreRegisteredAndExported() {
        XCTAssertEqual(SettingsKey.pointer(.speed), "pointer.speed")
        XCTAssertEqual(SettingsKey.pointer(.accelerationMode, profile: .mxMaster4), "pointer.mxMaster4.accelerationMode")
        XCTAssertEqual(SettingsKey.type(of: SettingsKey.pointer(.acceleration, profile: .generic)), .double)
        XCTAssertTrue(SettingsKey.isExportable(SettingsKey.pointer(.speed)))
    }

    func testResolution() {
        XCTAssertEqual(PointerMath.resolution(speed: 1), 400 * 65536, "the default")
        XCTAssertEqual(PointerMath.resolution(speed: 2), 200 * 65536, "twice as far is half the resolution")
        XCTAssertEqual(PointerMath.resolution(speed: 0.25), 1600 * 65536)
        XCTAssertEqual(PointerMath.resolution(speed: 1000), 10 * 65536, "never below the floor")
    }

    func testAcceleration() {
        XCTAssertEqual(PointerMath.acceleration(for: .standard, systemAcceleration: 0.6875), 45056)
        XCTAssertEqual(PointerMath.acceleration(for: PointerSettings(accelerationMode: .off), systemAcceleration: 0.6875), -65536)
        XCTAssertEqual(
            PointerMath.acceleration(for: PointerSettings(accelerationMode: .custom, acceleration: 1.5), systemAcceleration: 0.6875),
            98304
        )
    }
}

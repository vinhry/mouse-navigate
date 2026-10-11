import XCTest
@testable import MouseNavigateCore

final class PointerSettingsTests: XCTestCase {
    func testStandardLeavesThePointerAlone() {
        XCTAssertFalse(PointerSettings.standard.isActive)
        XCTAssertTrue(PointerSettings(accelerationMode: .off).isActive)
        XCTAssertTrue(PointerSettings(accelerationMode: .custom).isActive)
        XCTAssertFalse(PointerSettings(acceleration: 2).isActive, "a custom value only counts once chosen")
    }

    func testValuesAreKeptInRange() {
        XCTAssertEqual(PointerSettings(acceleration: -1).acceleration, 0)
        XCTAssertEqual(PointerSettings(acceleration: 9).acceleration, 5)
        XCTAssertEqual(PointerOverride(acceleration: 9).acceleration, 5)
        XCTAssertGreaterThan(PointerSettings.accelerationRange.upperBound, PointerSettings.systemMaximum, "faster than System Settings goes")
    }

    func testAnOverrideFollowsWhatItLeavesUnset() {
        let base = PointerSettings(accelerationMode: .custom, acceleration: 1.5)
        XCTAssertEqual(PointerOverride(accelerationMode: .off).applied(to: base),
                       PointerSettings(accelerationMode: .off, acceleration: 1.5))
        XCTAssertEqual(PointerOverride.none.applied(to: base), base)
    }

    func testFieldsRoundTripThroughPropertyLists() {
        let override = PointerOverride(accelerationMode: .custom, acceleration: 2)
        var copy = PointerOverride()
        for field in PointerField.allCases {
            copy.set(field, to: override.value(of: field))
        }
        XCTAssertEqual(copy, override)

        var wrong = PointerOverride()
        wrong.set(.acceleration, to: true)
        wrong.set(.accelerationMode, to: "sideways")
        XCTAssertEqual(wrong, .none, "values of the wrong kind stay unset")
    }

    func testKeysAreRegisteredAndExported() {
        XCTAssertEqual(SettingsKey.pointer(.acceleration), "pointer.acceleration")
        XCTAssertEqual(SettingsKey.pointer(.accelerationMode, profile: .mxMaster4), "pointer.mxMaster4.accelerationMode")
        XCTAssertEqual(SettingsKey.type(of: SettingsKey.pointer(.acceleration, profile: .generic)), .double)
        XCTAssertTrue(SettingsKey.isExportable(SettingsKey.pointer(.accelerationMode)))
    }

    func testAcceleration() {
        XCTAssertEqual(PointerMath.acceleration(for: .standard, systemAcceleration: 0.6875), 45056, "System Settings' own")
        XCTAssertEqual(PointerMath.acceleration(for: PointerSettings(accelerationMode: .off), systemAcceleration: 0.6875), -65536)
        XCTAssertEqual(
            PointerMath.acceleration(for: PointerSettings(accelerationMode: .custom, acceleration: 1.5), systemAcceleration: 0.6875),
            98304
        )
    }
}

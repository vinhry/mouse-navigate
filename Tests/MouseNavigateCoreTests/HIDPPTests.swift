import XCTest
@testable import MouseNavigateCore

/// Byte for byte what an MX Master 4 over Bluetooth answered when probed.
final class HIDPPTests: XCTestCase {
    private func report(_ bytes: [UInt8]) -> HIDPPMessage {
        HIDPPMessage(report: bytes + Array(repeating: 0, count: 20 - bytes.count))!
    }

    func testEncodingARequest() {
        let request = HIDPPRoot.findFeature(0x1B04, device: 0xFF, softwareID: 0x0A)
        XCTAssertEqual(request.bytes.count, 20)
        XCTAssertEqual(Array(request.bytes.prefix(6)), [0x11, 0xFF, 0x00, 0x0A, 0x1B, 0x04])
    }

    func testOnlyLongReportsAreRead() {
        XCTAssertNil(HIDPPMessage(report: [0x10, 0xFF, 0x00, 0x0A]))
        XCTAssertNil(HIDPPMessage(report: [0x11, 0xFF]))
    }

    func testAnswersAndErrors() {
        let request = ReprogControls.countRequest(feature: 13, device: 0xFF, softwareID: 0x0A)
        XCTAssertTrue(report([0x11, 0xFF, 0x0D, 0x0A, 0x09]).answers(request))
        XCTAssertFalse(report([0x11, 0xFF, 0x0D, 0x1A, 0x09]).answers(request), "another function")

        let error = report([0x11, 0xFF, 0xFF, 0x0D, 0x0A, 0x02])
        XCTAssertTrue(error.answers(request))
        XCTAssertEqual(error.error?.featureIndex, 13)
        XCTAssertEqual(error.error?.code, 2)
        XCTAssertFalse(error.isNotification)
    }

    func testReadingAControl() {
        // The gesture button: mouse button, reprogrammable, divertable, raw XY, analytics.
        let answer = report([0x11, 0xFF, 0x0D, 0x1A, 0x00, 0xC3, 0x00, 0x9C, 0x31, 0x00, 0x02, 0x03, 0x05])
        let control = ReprogControls.control(from: answer)
        XCTAssertEqual(control.id, 0x00C3)
        XCTAssertEqual(control.taskID, 0x009C)
        XCTAssertTrue(control.flags.contains([.mouseButton, .reprogrammable, .divertable, .rawXY]))
        XCTAssertFalse(control.flags.contains(.virtual))
    }

    func testDivertingNeverPersists() {
        let on = ReprogControls.divertRequest(0x00C4, divert: true, feature: 13, device: 0xFF, softwareID: 0x0A)
        XCTAssertEqual(Array(on.bytes.prefix(9)), [0x11, 0xFF, 0x0D, 0x3A, 0x00, 0xC4, 0x03, 0x00, 0x00])
        let off = ReprogControls.divertRequest(0x00C4, divert: false, feature: 13, device: 0xFF, softwareID: 0x0A)
        XCTAssertEqual(off.parameters[2], 0x02)
    }

    func testPressedControls() {
        let one = report([0x11, 0xFF, 0x0D, 0x00, 0x00, 0xC3])
        XCTAssertEqual(ReprogControls.pressedControls(in: one, feature: 13), [0x00C3])
        let two = report([0x11, 0xFF, 0x0D, 0x00, 0x00, 0xC3, 0x01, 0xA0])
        XCTAssertEqual(ReprogControls.pressedControls(in: two, feature: 13), [0x00C3, 0x01A0])
        let none = report([0x11, 0xFF, 0x0D, 0x00])
        XCTAssertEqual(ReprogControls.pressedControls(in: none, feature: 13), [])
        XCTAssertNil(ReprogControls.pressedControls(in: report([0x11, 0xFF, 0x0D, 0x0A, 0x00, 0xC3]), feature: 13), "an answer")
        XCTAssertNil(ReprogControls.pressedControls(in: one, feature: 12), "another feature")
    }

    func testDiscovery() {
        var discovery = HIDPPDiscovery()
        guard case .send(let findFeature) = discovery.start() else { return XCTFail() }
        XCTAssertEqual(findFeature.featureIndex, 0)

        guard case .send(let count) = discovery.receive(report([0x11, 0xFF, 0x00, 0x0A, 0x0D, 0x00, 0x06])) else { return XCTFail() }
        XCTAssertEqual(count.featureIndex, 13)
        XCTAssertNil(discovery.receive(report([0x11, 0xFF, 0x0D, 0x00, 0x00, 0xC3])), "a notification meanwhile")

        guard case .send = discovery.receive(report([0x11, 0xFF, 0x0D, 0x0A, 0x02])) else { return XCTFail() }
        guard case .send(let second) = discovery.receive(report([0x11, 0xFF, 0x0D, 0x1A, 0x00, 0xC3, 0x00, 0x9C, 0x31, 0, 2, 3, 5])) else {
            return XCTFail()
        }
        XCTAssertEqual(second.parameters[0], 1)
        let outcome = discovery.receive(report([0x11, 0xFF, 0x0D, 0x1A, 0x00, 0xC4, 0x00, 0x9D, 0x31, 0, 2, 3, 5]))
        guard case .ready(let feature, let controls) = outcome else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertEqual(feature, 13)
        XCTAssertEqual(controls.map(\.id), [0x00C3, 0x00C4])
    }

    func testDiscoveryOfAMouseWithoutTheFeature() {
        var discovery = HIDPPDiscovery()
        _ = discovery.start()
        XCTAssertEqual(discovery.receive(report([0x11, 0xFF, 0x00, 0x0A, 0x00])), .failed("the mouse has no reprogrammable controls"))
    }

    func testPressesAndReleases() {
        var diff = DivertedButtonDiff()
        XCTAssertEqual(diff.update([0x00C3]).pressed, [0x00C3])
        let both = diff.update([0x00C3, 0x01A0])
        XCTAssertEqual(both.pressed, [0x01A0])
        XCTAssertEqual(both.released, [])
        XCTAssertEqual(diff.update([0x01A0]).released, [0x00C3])
        XCTAssertEqual(diff.releaseAll(), [0x01A0])
        XCTAssertEqual(diff.update([]).released, [])
    }

    func testLogitechControlsAreButtonsPastCoreGraphics() {
        XCTAssertEqual(LogitechControl.gestureButton.button, 32)
        XCTAssertEqual(LogitechControl(button: 34), .hapticPanel)
        XCTAssertNil(LogitechControl(button: 5))
        XCTAssertTrue(LogitechControl.isVirtual(button: 33))
        XCTAssertFalse(LogitechControl.isVirtual(button: 9))
        XCTAssertEqual(LogitechControl.controls(for: .generic), [])
        XCTAssertTrue(LogitechControl.controls(for: .mxMaster4).contains(.hapticPanel))
        XCTAssertFalse(LogitechControl.controls(for: .mxMaster3).contains(.hapticPanel))
    }
}

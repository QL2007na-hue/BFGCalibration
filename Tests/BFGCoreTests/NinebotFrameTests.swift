import XCTest
@testable import BFGCore

/// Pins the wire format of the frames the iOS client will transmit. These are
/// byte-for-byte expectations derived from the Android implementation, so a
/// mistake here is caught on Linux rather than on a vehicle.
final class NinebotFrameTests: XCTestCase {

    func testWriteProfileFrame() {
        XCTAssertEqual([0x5A, 0xA5, 0x01, 0x3E, 0x10, 0x02, 0x00, 0x51],
                       NinebotFrame.writeProfile(0x51))
        // The profile byte is masked to eight bits.
        XCTAssertEqual([0x5A, 0xA5, 0x01, 0x3E, 0x10, 0x02, 0x00, 0x22],
                       NinebotFrame.writeProfile(0x122))
    }

    func testReadBfgWordFrame() {
        XCTAssertEqual([0x5A, 0xA5, 0x01, 0x3E, 0x10, 0x01, 0x1C, 0x02],
                       NinebotFrame.readBfgWord(register: 0x1C))
    }

    /// The machine-key read is an ordinary read frame whose *data* byte is the
    /// requested length. Both halves matter: index 0x13 with any other length is
    /// refused by the receiver, so a frame that looked plausible but asked for
    /// two bytes would fail on hardware while passing a looser expectation.
    func testReadClusterSecretKeyFrame() {
        let frame = NinebotFrame.readClusterSecretKey
        XCTAssertEqual([0x5A, 0xA5, 0x01, 0x3E, 0x01, 0x01, 0x13, 0x28], frame)
        XCTAssertEqual(1, frame[2], "LEN 覆盖的是数据段长度")
        XCTAssertEqual(0x01, frame[5], "读请求的 CMD 必须是 0x01")
        XCTAssertEqual(0x13, frame[6], "index 必须是 0x13")
        XCTAssertEqual(40, frame[7], "长度字节必须是 40，否则仪表拒绝这次读取")
    }

    func testAuthenticateFrameCarriesSerial() throws {
        let serial = Array("ABCD1234EFGH56".utf8)
        let frame = try NinebotFrame.authenticate(serial14: serial)
        XCTAssertEqual(21, frame.count)
        XCTAssertEqual([0x5A, 0xA5, 0x0E, 0x3E, 0x04, 0x5D, 0x00], Array(frame.prefix(7)))
        XCTAssertEqual(serial, Array(frame.suffix(14)))
    }

    func testAuthenticateRejectsWrongSerialLength() {
        XCTAssertThrowsError(try NinebotFrame.authenticate(serial14: [1, 2, 3])) { error in
            XCTAssertEqual(error as? NinebotFrame.Failure, .serialMustBe14Bytes)
        }
    }

    func testSetPasswordFrameLayout() {
        let password = [UInt8](repeating: 7, count: 32)
        let frame = NinebotFrame.setPassword(password32: password)
        XCTAssertEqual(39, frame.count)
        XCTAssertEqual([0x5A, 0xA5, 0x20, 0x3E, 0x04, 0x5C, 0x00], Array(frame.prefix(7)))
        XCTAssertEqual(password, Array(frame.suffix(32)))
    }

    func testFixedFramesMatchAndroidConstants() {
        XCTAssertEqual("5AA5003E045B00", Hex.encode(NinebotFrame.preComm))
        XCTAssertEqual("5AA5013E10010001", Hex.encode(NinebotFrame.readProfile))
        XCTAssertEqual("5AA5013E10010201", Hex.encode(NinebotFrame.readSoc))
        XCTAssertEqual("5AA5013E10011C02", Hex.encode(NinebotFrame.readCapacity))
        XCTAssertEqual("5AA5013E01019202", Hex.encode(NinebotFrame.readDisConfig))
        XCTAssertEqual("5AA5013E01011E02", Hex.encode(NinebotFrame.readDisEnergyWh))
        XCTAssertEqual("5AA5013E01014402", Hex.encode(NinebotFrame.readDisRemainingCapacity))
    }

    func testIsFrameChecksSourceDestinationAndCommand() {
        let reply: [UInt8] = [0x5A, 0xA5, 0x00, 0x04, 0x3E, 0x5B, 0x00]
        XCTAssertTrue(NinebotFrame.isFrame(reply, src: 0x04, dst: 0x3E, cmd: 0x5B))
        XCTAssertFalse(NinebotFrame.isFrame(reply, src: 0x04, dst: 0x3E, cmd: 0x5C))
        XCTAssertFalse(NinebotFrame.isFrame(reply, src: 0x10, dst: 0x3E, cmd: 0x5B))
        XCTAssertFalse(NinebotFrame.isFrame([0x5A, 0xA5], src: 0x04, dst: 0x3E, cmd: 0x5B))
        XCTAssertFalse(NinebotFrame.isFrame(nil, src: 0x04, dst: 0x3E, cmd: 0x5B))
    }

    func testReadLe16IsLittleEndian() {
        // The low byte comes first: swapping the bytes must change the value.
        XCTAssertEqual(0x00C1, NinebotFrame.readLe16([0xC1, 0x00], offset: 0))
        XCTAssertEqual(0xC100, NinebotFrame.readLe16([0x00, 0xC1], offset: 0))
        XCTAssertEqual(0x1E00, NinebotFrame.readLe16([0x00, 0x1E], offset: 0))
        // Reading at a non-zero offset leaves the preceding byte alone.
        XCTAssertEqual(0x00C1, NinebotFrame.readLe16([0xAA, 0xC1, 0x00], offset: 1))
    }
}
